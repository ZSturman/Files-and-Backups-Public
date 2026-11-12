#!/usr/bin/env bash
# Physical-device UI tests over Tailscale against a tailnet-only Samba fixture.
#
#   scripts/run-device-tests.sh <device-udid>
#
# Starts (or reuses) the fixture bound to this Mac's Tailscale IPv4, runs
# DeviceTransferTests on the device, and while it runs freezes the Samba
# container for 45 s once the first partial upload passes FB_STALL_AFTER_MB (8) (a real
# network stall for the phone). Afterwards prints server-side SHA-256 and
# compares them with the deterministic fixture contents.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?device UDID required}"
TS_IP="$(tailscale ip -4 | head -1)"
export FB_SMB_FIXTURE_BIND="$TS_IP" FB_SMB_FIXTURE_PORT="${FB_SMB_FIXTURE_PORT:-4446}"
CONTAINER="files-backups-smb-fixture-${TS_IP//./-}"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || scripts/smb-fixture.sh start >/dev/null
eval "$(scripts/smb-fixture.sh env)"
MB="${FB_UITEST_FIXTURE_MB:-48}"
STALL_BLOCKS=$(( ${FB_STALL_AFTER_MB:-8} * 2048 ))   # find -size counts 512-byte blocks
ROOT="dev-$(openssl rand -hex 3)"
docker exec "$CONTAINER" sh -c "mkdir /shared/$ROOT && chown fixture:smb /shared/$ROOT"
echo "Device $DEVICE → smb://$TS_IP:$FB_SMB_FIXTURE_PORT/Fixture/$ROOT (fixture ${MB} MB)"

LOG_DIR=".build/device-$ROOT"
mkdir -p "$LOG_DIR"
(
  # Network stall injector (runs once).
  for _ in $(seq 1 600); do
    size="$(docker exec "$CONTAINER" sh -c "find /shared/$ROOT -name '.fbpart-*' -size +$STALL_BLOCKS | head -1" 2>/dev/null || true)"
    if [[ -n "$size" ]]; then
      echo "$(date +%T) stalling server (docker pause) for 45 s" >> "$LOG_DIR/interrupt.log"
      docker pause "$CONTAINER" >/dev/null
      sleep 45
      docker unpause "$CONTAINER" >/dev/null
      echo "$(date +%T) server resumed" >> "$LOG_DIR/interrupt.log"
      exit 0
    fi
    sleep 1
  done
) &
INJECTOR=$!

xcodegen generate >/dev/null
export TEST_RUNNER_FB_SMB_TEST_HOST="$FB_SMB_TEST_HOST" TEST_RUNNER_FB_SMB_TEST_PORT="$FB_SMB_TEST_PORT"
export TEST_RUNNER_FB_SMB_TEST_SHARE="$FB_SMB_TEST_SHARE" TEST_RUNNER_FB_SMB_TEST_USER="$FB_SMB_TEST_USER"
export TEST_RUNNER_FB_SMB_TEST_PASSWORD="$FB_SMB_TEST_PASSWORD" TEST_RUNNER_FB_SMB_TEST_ROOT="$ROOT"
export TEST_RUNNER_FB_UITEST_FIXTURE_MB="$MB"
set +e
xcodebuild test -project FilesBackups.xcodeproj -scheme FilesBackups -destination "id=$DEVICE" \
  -only-testing:FilesBackupsUITests/DeviceTransferTests -allowProvisioningUpdates \
  -derivedDataPath .build/DerivedData-device -resultBundlePath "$LOG_DIR/results.xcresult" \
  > "$LOG_DIR/xcodebuild.log" 2>&1
STATUS=$?
set -e
kill "$INJECTOR" 2>/dev/null || true
docker unpause "$CONTAINER" >/dev/null 2>&1 || true
grep -E "Test Case|error:|\*\* TEST" "$LOG_DIR/xcodebuild.log" || tail -20 "$LOG_DIR/xcodebuild.log"
cat "$LOG_DIR/interrupt.log" 2>/dev/null || echo "(no network stall was injected)"

echo "Server-side SHA-256:"
docker exec "$CONTAINER" sh -c "cd /shared/$ROOT && find . -type f -exec sha256sum {} + | sort -k2" | tee "$LOG_DIR/server-hashes.txt"
set +e
python3 - "$LOG_DIR/server-hashes.txt" "$MB" <<'EOF'
import hashlib, sys
lines = open(sys.argv[1]).read().split("\n")
mb = int(sys.argv[2])
expected = {
    "notes.txt": hashlib.sha256(b"Files & Backups acceptance fixture\n").hexdigest(),
    "Day 1/photo.bin": hashlib.sha256(bytes((i * 7) & 0xFF for i in range(750_000))).hexdigest(),
    "Day 1/Café ☕️/menu.txt": hashlib.sha256("crème brûlée\n".encode()).hexdigest(),
    "Day 2/empty.dat": hashlib.sha256(b"").hexdigest(),
}
if mb:
    n = mb << 20
    expected["Day 2/large.bin"] = hashlib.sha256(bytes(((i * 31) ^ (i >> 11)) & 0xFF for i in range(n))).hexdigest()
found = {}
for line in filter(None, lines):
    digest, path = line.split("  ", 1)
    found[path[2:]] = digest
ok = True
for folder in ("FB Acceptance", "FB Acceptance (2)"):
    for rel, digest in expected.items():
        actual = found.get(f"{folder}/{rel}")
        status = "match" if actual == digest else "MISMATCH/MISSING"
        ok &= actual == digest
        print(f"{status:16} {folder}/{rel}")
leftovers = [p for p in found if ".fbpart-" in p]
print("temp files left:", leftovers or "none")
sys.exit(0 if ok and not leftovers else 1)
EOF
VERIFY=$?
exit $(( STATUS != 0 || VERIFY != 0 ))
