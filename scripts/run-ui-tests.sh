#!/usr/bin/env bash
# Runs the iOS Simulator UI flow against the disposable Samba fixture.
# Requires: scripts/smb-fixture.sh start (Docker). Each run uses a fresh
# folder on the fixture share; prints it so server-side hashes can be checked.
set -euo pipefail
cd "$(dirname "$0")/.."

SIMULATOR="${FB_SIMULATOR:-iPhone 17 Pro}"
eval "$(scripts/smb-fixture.sh env)"
ROOT="ui-$(openssl rand -hex 3)"
docker exec files-backups-smb-fixture sh -c "mkdir /shared/$ROOT && chown fixture:smb /shared/$ROOT"
echo "Fixture folder: $ROOT"

xcodegen generate >/dev/null
export TEST_RUNNER_FB_SMB_TEST_HOST="$FB_SMB_TEST_HOST"
export TEST_RUNNER_FB_SMB_TEST_PORT="$FB_SMB_TEST_PORT"
export TEST_RUNNER_FB_SMB_TEST_SHARE="$FB_SMB_TEST_SHARE"
export TEST_RUNNER_FB_SMB_TEST_USER="$FB_SMB_TEST_USER"
export TEST_RUNNER_FB_SMB_TEST_PASSWORD="$FB_SMB_TEST_PASSWORD"
export TEST_RUNNER_FB_SMB_TEST_ROOT="$ROOT"
rm -rf ".build/ui-results.xcresult"
xcodebuild test -project FilesBackups.xcodeproj -scheme FilesBackups \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -only-testing:FilesBackupsUITests/AddStorageFlowTests \
  -derivedDataPath .build/DerivedData -resultBundlePath .build/ui-results.xcresult \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|error:|\*\* TEST" || true

echo "Server-side SHA-256 of uploaded files:"
docker exec files-backups-smb-fixture sh -c "cd /shared/$ROOT && find . -type f -exec sha256sum {} + | sort -k2" || true
