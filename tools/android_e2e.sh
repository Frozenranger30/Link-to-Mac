#!/usr/bin/env bash
# Runs inside the Android emulator job: installs the e2e APK, pairs it with tools/fake_mac.py
# and checks TLS, authentication, status, requests and a file upload.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${PYTHON:-python3}
APK=android/app/build/outputs/apk/e2e/app-e2e.apk

adb wait-for-device
adb install -r -g "$APK"
adb logcat -c || true
adb forward tcp:47800 tcp:47800
adb forward tcp:47801 tcp:47801

rm -f /tmp/qr.json
# 10.0.2.2 is the host machine as seen from the emulator.
$PY tools/fake_mac.py --qr-host 10.0.2.2 --phone-host 127.0.0.1 --qr-out /tmp/qr.json --timeout 120 > /tmp/fake_mac.log 2>&1 &
MAC_PID=$!
for i in $(seq 1 30); do [ -s /tmp/qr.json ] && break; sleep 1; done
QR64=$(base64 -w0 < /tmp/qr.json)
adb shell am start -n de.linktomac/.e2e.E2ePairActivity --es qr64 "$QR64"

STATUS=0
wait $MAC_PID || STATUS=$?
echo "===== fake_mac.py ====="
cat /tmp/fake_mac.log
if [ $STATUS -ne 0 ]; then
  echo "===== logcat (app) ====="
  adb logcat -d | grep -iE "linktomac|AndroidRuntime|ControlConnection|LinkService|FileBridge" | tail -200 || true
fi
exit $STATUS
