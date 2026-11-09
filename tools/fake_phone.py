#!/usr/bin/env python3
"""
Fake Android phone for end-to-end tests of the Mac app (and for trying the Mac app without a phone).

It implements the phone side of docs/PROTOCOL.md:
  * TLS server on 47800 (control) and 47801 (data) with a self-signed P-256 certificate
  * pairing: receives the QR JSON on a local helper port (47899) and sends pair.request to the Mac
  * auth: verifies the Mac's ECDSA signature with the key received in pair.accept
  * answers a few requests with the examples from shared/protocol-examples

Uses the `cryptography` package when installed, otherwise the `openssl` command line tool.
"""
import argparse
import base64
import datetime
import hashlib
import hmac
import json
import os
import shutil
import socket
import subprocess
import ssl
import struct
import sys
import tempfile
import threading
import time
import uuid

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    HAVE_CRYPTOGRAPHY = True
except ImportError:  # fall back to the openssl CLI
    HAVE_CRYPTOGRAPHY = False

HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLES = os.path.join(HERE, "..", "shared", "protocol-examples")
PHOTO_BYTES = bytes((i * 7) % 256 for i in range(300_000))  # deterministic "photo"

state = {"mac_key": None, "mac_key_fp": None, "token": None, "events": []}
lock = threading.Lock()


def log(*a):
    print("[fake-phone]", *a, flush=True)
    with lock:
        state["events"].append(" ".join(str(x) for x in a))


def make_cert(tmp):
    cert_pem = os.path.join(tmp, "cert.pem")
    key_pem = os.path.join(tmp, "key.pem")
    if HAVE_CRYPTOGRAPHY:
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "LinkToMac Fake Phone")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=365)).sign(key, hashes.SHA256()))
        with open(cert_pem, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        with open(key_pem, "wb") as f:
            f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    else:
        openssl = shutil.which("openssl") or "/usr/bin/openssl"
        subprocess.run([openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key_pem], check=True)
        subprocess.run([openssl, "req", "-new", "-x509", "-key", key_pem, "-out", cert_pem, "-days", "365",
                        "-subj", "/CN=LinkToMac Fake Phone"], check=True)
    with open(cert_pem) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    return cert_pem, key_pem, hashlib.sha256(der).hexdigest()


def verify_signature(pub_der, signature, message):
    """ECDSA P-256 / SHA-256 verification of a DER signature."""
    if HAVE_CRYPTOGRAPHY:
        try:
            serialization.load_der_public_key(pub_der).verify(signature, message, ec.ECDSA(hashes.SHA256()))
            return True
        except Exception as e:  # noqa: BLE001
            log("signature invalid:", e)
            return False
    tmp = tempfile.mkdtemp()
    paths = {n: os.path.join(tmp, n) for n in ("pub.pem", "sig.der", "msg.bin")}
    b64 = base64.encodebytes(pub_der).decode()
    with open(paths["pub.pem"], "w") as f:
        f.write("-----BEGIN PUBLIC KEY-----\n" + b64 + "-----END PUBLIC KEY-----\n")
    with open(paths["sig.der"], "wb") as f:
        f.write(signature)
    with open(paths["msg.bin"], "wb") as f:
        f.write(message)
    openssl = shutil.which("openssl") or "/usr/bin/openssl"
    r = subprocess.run([openssl, "dgst", "-sha256", "-verify", paths["pub.pem"], "-signature", paths["sig.der"], paths["msg.bin"]],
                       capture_output=True, text=True)
    if r.returncode != 0:
        log("signature invalid:", r.stdout, r.stderr)
    return r.returncode == 0


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def read_frame(sock):
    (length,) = struct.unpack(">I", read_exact(sock, 4))
    return json.loads(read_exact(sock, length).decode("utf-8"))


write_lock = threading.Lock()


def write_frame(sock, obj):
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    with write_lock:
        sock.sendall(struct.pack(">I", len(data)) + data)


def env(type_, body, reply_to=None):
    e = {"id": str(uuid.uuid4()), "type": type_, "ts": int(time.time() * 1000), "body": body}
    if reply_to:
        e["replyTo"] = reply_to
    return e


def example_body(name):
    with open(os.path.join(EXAMPLES, name + ".json"), encoding="utf-8") as f:
        return json.load(f)["body"]


# ---- Pairing ------------------------------------------------------------------------

def pair(qr, cert_fp):
    token = base64.b64decode(qr["pairToken"])
    proof = base64.b64encode(hmac.new(token, f"{cert_fp}|{qr['keyFingerprint']}".encode(), hashlib.sha256).digest()).decode()
    hosts = [qr["host"]] + qr.get("hosts", [])
    hosts = ["127.0.0.1"] + [h for h in hosts if h]
    for host in hosts:
        try:
            with socket.create_connection((host, qr["port"]), timeout=5) as s:
                s.settimeout(120)
                write_frame(s, env("pair.request", {"deviceName": "Fake Phone", "model": "CI-1", "port": 47800,
                                                    "certFingerprint": cert_fp, "proof": proof}))
                reply = read_frame(s)
                if reply["type"] != "pair.accept":
                    log("pairing rejected", reply)
                    return
                key_der = base64.b64decode(reply["body"]["publicKey"])
                if hashlib.sha256(key_der).hexdigest() != qr["keyFingerprint"]:
                    log("PAIRING KEY MISMATCH")
                    return
                state["mac_key"] = key_der
                state["mac_key_fp"] = qr["keyFingerprint"]
                log("paired with", reply["body"]["macName"])
                return
        except Exception as e:  # noqa: BLE001
            log("pair via", host, "failed:", e)


def qr_helper(cert_fp, port):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen()
    while True:
        c, _ = srv.accept()
        with c:
            data = b""
            while not data.endswith(b"\n"):
                chunk = c.recv(65536)
                if not chunk:
                    break
                data += chunk
            try:
                qr = json.loads(data.decode())
            except Exception:  # noqa: BLE001
                continue
            c.sendall(b"ok\n")
        threading.Thread(target=pair, args=(qr, cert_fp), daemon=True).start()


# ---- Control channel ------------------------------------------------------------------

def handle_control(conn, cert_fp):
    challenge = base64.b64encode(os.urandom(32)).decode()
    authed = False
    try:
        write_frame(conn, env("hello", {"deviceName": "Fake Phone", "model": "CI-1", "appVersion": "test",
                                         "protocolVersion": 1, "capabilities": ["status", "sms", "photos"],
                                         "challenge": challenge}))
        while True:
            msg = read_frame(conn)
            t = msg["type"]
            if t == "ping":
                write_frame(conn, env("pong", {}, msg["id"]))
            elif t == "hello":
                pass
            elif t == "auth":
                ok = False
                key = state["mac_key"]
                if key is not None and msg["body"]["keyFingerprint"] == state["mac_key_fp"]:
                    ok = verify_signature(key, base64.b64decode(msg["body"]["signature"]),
                                          f"linktomac-auth|{challenge}|{cert_fp}".encode())
                if not ok:
                    log("AUTH FAILED")
                    write_frame(conn, env("error", {"code": "unauthorized", "message": "unknown mac"}))
                    return
                authed = True
                state["control"] = conn
                state["token"] = base64.b64encode(os.urandom(32)).decode()
                write_frame(conn, env("auth.ok", {"sessionToken": state["token"]}, msg["id"]))
                log("auth ok")
                write_frame(conn, env("status.update", {"battery": 77, "charging": True, "wifiSignal": 3,
                                                         "network": "wifi", "cellSignal": 2, "dnd": False}))
                write_frame(conn, env("notification.posted", example_body("notification.posted")))
            elif not authed:
                continue
            elif t == "sms.threads.get":
                write_frame(conn, env("sms.threads", example_body("sms.threads"), msg["id"]))
            elif t == "sms.messages.get":
                write_frame(conn, env("sms.messages", example_body("sms.messages"), msg["id"]))
            elif t == "sms.send":
                write_frame(conn, env("sms.sent", {"ok": True}, msg["id"]))
                log("sms sent:", msg["body"]["text"])
            elif t == "calllog.get":
                write_frame(conn, env("calllog", example_body("calllog"), msg["id"]))
            elif t == "contacts.get":
                write_frame(conn, env("contacts", example_body("contacts"), msg["id"]))
            elif t == "photos.list":
                write_frame(conn, env("photos", example_body("photos"), msg["id"]))
            elif t == "photo.get":
                tid = msg["body"]["transferId"]
                write_frame(conn, env("file.offer", {"transferId": tid, "name": "IMG_TEST.jpg", "size": len(PHOTO_BYTES),
                                                      "mime": "image/jpeg", "sha256": hashlib.sha256(PHOTO_BYTES).hexdigest(),
                                                      "purpose": "photo"}, msg["id"]))
            elif t == "file.done":
                log("file.done", msg["body"])
            elif t == "file.offer":
                write_frame(conn, env("file.accept", {"transferId": msg["body"]["transferId"]}, msg["id"]))
                state.setdefault("uploads", {})[msg["body"]["transferId"]] = msg["body"]
            else:
                log("received", t)
    except Exception as e:  # noqa: BLE001
        log("control closed:", e)
    finally:
        conn.close()


def handle_data(conn):
    try:
        header = read_frame(conn)
        if header.get("sessionToken") != state["token"]:
            log("DATA BAD TOKEN")
            return
        if header.get("direction") == "download":
            for i in range(0, len(PHOTO_BYTES), 65536):
                conn.sendall(PHOTO_BYTES[i:i + 65536])
            log("photo sent")
        elif header.get("direction") == "upload":
            offer = state.get("uploads", {}).get(header["transferId"])
            data = read_exact(conn, offer["size"])
            ok = hashlib.sha256(data).hexdigest() == offer["sha256"]
            log("upload received ok=%s" % ok)
            write_frame(state["control"], env("file.done", {"transferId": header["transferId"], "ok": ok}))
    except Exception as e:  # noqa: BLE001
        log("data error:", e)
    finally:
        conn.close()


def tls_server(port, ctx, handler):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen()
    while True:
        raw, addr = srv.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
        except Exception as e:  # noqa: BLE001
            log("tls handshake failed from", addr, e)
            raw.close()
            continue
        threading.Thread(target=handler, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qr-port", type=int, default=47899)
    ap.add_argument("--qr", help="QR JSON to pair with immediately")
    args = ap.parse_args()
    tmp = tempfile.mkdtemp()
    cert_pem, key_pem, fp = make_cert(tmp)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_pem, key_pem)
    log("certificate fingerprint", fp)
    threading.Thread(target=tls_server, args=(47800, ctx, lambda c: handle_control(c, fp)), daemon=True).start()
    threading.Thread(target=tls_server, args=(47801, ctx, handle_data), daemon=True).start()
    threading.Thread(target=qr_helper, args=(fp, args.qr_port), daemon=True).start()
    if args.qr:
        threading.Thread(target=pair, args=(json.loads(args.qr), fp), daemon=True).start()
    log("ready")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.exit(main())
