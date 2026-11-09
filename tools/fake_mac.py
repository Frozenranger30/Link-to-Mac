#!/usr/bin/env python3
"""
Fake Mac for end-to-end tests of the Android app (and of tools/fake_phone.py).

Flow: creates a P-256 identity and a pairing QR payload, waits for pair.request on the pairing
port, accepts it, connects to the phone with certificate pinning, authenticates with an ECDSA
signature and runs a few requests. Exit code 0 = all checks passed.

Requires: pip install cryptography
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import ssl
import struct
import sys
import time
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


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


def write_frame(sock, obj):
    data = json.dumps(obj).encode("utf-8")
    sock.sendall(struct.pack(">I", len(data)) + data)


def env(type_, body, reply_to=None):
    e = {"id": str(uuid.uuid4()), "type": type_, "ts": int(time.time() * 1000), "body": body}
    if reply_to:
        e["replyTo"] = reply_to
    return e


def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qr-host", default="127.0.0.1", help="address the phone uses to reach this script")
    ap.add_argument("--pair-port", type=int, default=47805)
    ap.add_argument("--phone-host", default="127.0.0.1", help="address of the phone's TLS ports")
    ap.add_argument("--phone-port", type=int, default=47800)
    ap.add_argument("--data-port", type=int, default=47801)
    ap.add_argument("--qr-out", help="write the QR JSON to this file")
    ap.add_argument("--qr-send", help="host:port of fake_phone's QR helper")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    key = ec.generate_private_key(ec.SECP256R1())
    pub_der = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    key_fp = hashlib.sha256(pub_der).hexdigest()
    token = os.urandom(32)
    qr = {"v": 1, "name": "Fake Mac", "host": args.qr_host, "hosts": [args.qr_host], "port": args.pair_port,
          "keyFingerprint": key_fp, "pairToken": base64.b64encode(token).decode()}
    qr_json = json.dumps(qr)

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.pair_port))
    srv.listen()
    srv.settimeout(args.timeout)
    print("QR:", qr_json, flush=True)
    if args.qr_out:
        with open(args.qr_out, "w") as f:
            f.write(qr_json)
    if args.qr_send:
        h, p = args.qr_send.split(":")
        with socket.create_connection((h, int(p)), timeout=10) as s:
            s.sendall(qr_json.encode() + b"\n")

    # 1. Pairing
    conn, addr = srv.accept()
    conn.settimeout(30)
    req = read_frame(conn)
    check(req["type"] == "pair.request", "received pair.request from %s" % addr[0])
    body = req["body"]
    expected = base64.b64encode(hmac.new(token, f"{body['certFingerprint']}|{key_fp}".encode(), hashlib.sha256).digest()).decode()
    check(hmac.compare_digest(expected, body["proof"]), "pairing proof (HMAC) is valid")
    write_frame(conn, env("pair.accept", {"macName": "Fake Mac", "publicKey": base64.b64encode(pub_der).decode()}, req["id"]))
    time.sleep(0.5)
    conn.close()
    phone_fp = body["certFingerprint"]
    print("phone:", body["deviceName"], body["model"], "fingerprint", phone_fp, flush=True)

    # 2. TLS connection with pinning (retry while the phone service starts)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    def connect(port):
        deadline = time.time() + 60
        last = None
        while time.time() < deadline:
            try:
                raw = socket.create_connection((args.phone_host, port), timeout=10)
                s = ctx.wrap_socket(raw)
                der = s.getpeercert(binary_form=True)
                check(hashlib.sha256(der).hexdigest() == phone_fp, "TLS certificate matches pinned fingerprint (port %d, %s)" % (port, s.version()))
                return s
            except (OSError, ssl.SSLError) as e:
                last = e
                time.sleep(2)
        check(False, "connect to phone port %d: %s" % (port, last))

    s = connect(args.phone_port)
    s.settimeout(30)
    hello = read_frame(s)
    check(hello["type"] == "hello" and hello["body"].get("challenge"), "phone sent hello with challenge")
    msg = f"linktomac-auth|{hello['body']['challenge']}|{phone_fp}".encode()
    sig = key.sign(msg, ec.ECDSA(hashes.SHA256()))
    write_frame(s, env("auth", {"keyFingerprint": key_fp, "signature": base64.b64encode(sig).decode()}))
    write_frame(s, env("hello", {"deviceName": "Fake Mac", "appVersion": "test", "protocolVersion": 1, "capabilities": []}))

    token_ok = None
    got = {}
    pending = {}

    def request(type_, body):
        e = env(type_, body)
        pending[e["id"]] = type_
        write_frame(s, e)
        return e["id"]

    deadline = time.time() + 40
    ping_id = None
    threads_id = None
    while time.time() < deadline:
        m = read_frame(s)
        t = m["type"]
        if t == "auth.ok":
            token_ok = m["body"]["sessionToken"]
            check(True, "authenticated (auth.ok)")
            ping_id = request("ping", {})
            threads_id = request("sms.threads.get", {"limit": 10})
            request("photos.list", {"offset": 0, "limit": 3})
            request("calllog.get", {"limit": 5})
        elif t == "error" and not token_ok:
            check(False, "auth failed: %s" % m["body"])
        elif t == "status.update":
            got["status"] = m["body"]
            print("status:", m["body"], flush=True)
        elif t == "pong" and m.get("replyTo") == ping_id:
            got["pong"] = True
        elif m.get("replyTo") in pending:
            got[t] = m["body"]
            print("reply", t, json.dumps(m["body"])[:200], flush=True)
        if token_ok and "status" in got and "pong" in got and ("sms.threads" in got or "error" in got) \
                and ("photos" in got or "error" in got) and ("calllog" in got or "error" in got):
            break
    check(token_ok is not None, "session established")
    check("status" in got and 0 <= got["status"]["battery"] <= 100, "status.update with battery")
    check(got.get("pong") is True, "heartbeat ping/pong")

    # 3. Upload a file Mac -> phone over the data channel
    payload = os.urandom(200_000)
    tid = str(uuid.uuid4())
    write_frame(s, env("file.offer", {"transferId": tid, "name": "e2e-test.bin", "size": len(payload),
                                      "mime": "application/octet-stream", "sha256": hashlib.sha256(payload).hexdigest()}))
    accepted = False
    deadline = time.time() + 20
    while time.time() < deadline and not accepted:
        m = read_frame(s)
        if m["type"] == "file.accept" and m["body"]["transferId"] == tid:
            accepted = True
        elif m["type"] == "file.reject":
            check(False, "file rejected: %s" % m["body"])
    check(accepted, "file.offer accepted")
    d = connect(args.data_port)
    write_frame(d, {"sessionToken": token_ok, "transferId": tid, "direction": "upload"})
    for i in range(0, len(payload), 65536):
        d.sendall(payload[i:i + 65536])
    done = None
    deadline = time.time() + 30
    while time.time() < deadline and done is None:
        m = read_frame(s)
        if m["type"] == "file.done" and m["body"]["transferId"] == tid:
            done = m["body"]
    d.close()
    check(done is not None and done["ok"], "upload verified by phone (file.done ok)")
    print("ALL CHECKS PASSED", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
