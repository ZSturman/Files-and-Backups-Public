#!/usr/bin/env bash
# Physical-device UI test against the live Home Services server.
#
#   scripts/run-device-hs-tests.sh <device-udid> [base-url]
#
# Creates a disposable fb-device-test-* folder in the server's files root,
# runs DeviceHomeServicesTests inside it, prints what the server holds
# (paths + SHA-256 computed by the server on download), then moves the
# folder to the managed Trash (restorable for 7 days). The token is read
# from the login Keychain and never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?device UDID required}"
URL="${2:-https://host.example.net:8443}"
TOKEN="$(security find-generic-password -a home-services -s home-services-token-files-backups -w)"
ROOT="fb-device-test-$(openssl rand -hex 3)"
LOG_DIR=".build/device-hs-$ROOT"
mkdir -p "$LOG_DIR"
api() { curl -sS --fail-with-body -H "Authorization: Bearer $TOKEN" -H "Home-Services-Contract: 1" "$@"; }

api -X POST -H 'Content-Type: application/json' -d "{\"path\":\"$ROOT\"}" "$URL/api/v1/storage/files/directories" >/dev/null
echo "Device $DEVICE → $URL files/$ROOT"

xcodegen generate >/dev/null
export TEST_RUNNER_FB_HS_TEST_URL="$URL" TEST_RUNNER_FB_HS_TEST_TOKEN="$TOKEN" TEST_RUNNER_FB_HS_TEST_ROOT="$ROOT"
export TEST_RUNNER_FB_UITEST_FIXTURE_MB="${FB_UITEST_FIXTURE_MB:-20}"
set +e
xcodebuild test -project FilesBackups.xcodeproj -scheme FilesBackups -destination "id=$DEVICE" \
  -only-testing:FilesBackupsUITests/DeviceHomeServicesTests -allowProvisioningUpdates \
  -derivedDataPath .build/DerivedData-device -resultBundlePath "$LOG_DIR/results.xcresult" > "$LOG_DIR/xcodebuild.log" 2>&1
STATUS=$?
set -e
grep -E "Test Case|error:|\*\* TEST" "$LOG_DIR/xcodebuild.log" | sed "s/$TOKEN/<redacted>/g" || tail -20 "$LOG_DIR/xcodebuild.log"

echo "Server contents of files/$ROOT (server-side listing):"
python3 - "$URL" "$ROOT" <<EOF || echo "(server listing failed)"
import json, sys, urllib.request, urllib.parse, hashlib
url, root = sys.argv[1], sys.argv[2]
headers = {"Authorization": "Bearer $TOKEN", "Home-Services-Contract": "1"}
def get(route, **query):
    req = urllib.request.Request(url + "/api/v1/" + route + "?" + urllib.parse.urlencode(query), headers=headers)
    with urllib.request.urlopen(req) as r: return r.read()
def walk(path):
    for e in json.loads(get("storage/files/entries", path=path, limit=500))["entries"]:
        if e["kind"] == "directory":
            print(f"  dir   {e['path']}")
            walk(e["path"])
        else:
            digest = hashlib.sha256(get("storage/files/content", path=e["path"])).hexdigest()
            print(f"  file  {e['path']}  {e['size']} B  sha256 {digest[:16]}…")
walk(root)
EOF

api -X POST -H 'Content-Type: application/json' -d "{\"path\":\"$ROOT\"}" "$URL/api/v1/storage/files/trash" >/dev/null && echo "Moved files/$ROOT to the managed Trash."
exit $STATUS
