#!/usr/bin/env bash
# Disposable Samba (SMB2/3) fixture for FileCoreSMB integration tests.
#
#   scripts/smb-fixture.sh start   # starts container, prints env exports
#   scripts/smb-fixture.sh env     # prints env exports for a running fixture
#   scripts/smb-fixture.sh hashes  # server-side SHA-256 of every file on the share
#   scripts/smb-fixture.sh stop    # removes container and its data
#
# Binds only to 127.0.0.1. Uses a random per-run password stored with
# owner-only permissions in the fixture state directory, never in Git.
set -euo pipefail

# FB_SMB_FIXTURE_BIND=<tailscale IP> exposes a second, tailnet-only fixture
# for physical devices; it never binds 0.0.0.0.
BIND="${FB_SMB_FIXTURE_BIND:-127.0.0.1}"
SUFFIX="${BIND//./-}"
NAME="files-backups-smb-fixture"
[[ "$BIND" != "127.0.0.1" ]] && NAME="files-backups-smb-fixture-$SUFFIX"
IMAGE="dockurr/samba:latest"
PORT="${FB_SMB_FIXTURE_PORT:-4445}"
STATE_DIR="${TMPDIR:-/tmp}/$NAME"
SHARE="Fixture"
SMB_USER="fixture"

print_env() {
  local password
  password="$(cat "$STATE_DIR/password")"
  echo "export FB_SMB_TEST_HOST=$BIND"
  echo "export FB_SMB_TEST_PORT=$PORT"
  echo "export FB_SMB_TEST_SHARE=$SHARE"
  echo "export FB_SMB_TEST_USER=$SMB_USER"
  echo "export FB_SMB_TEST_PASSWORD=$password"
}

case "${1:-}" in
  start)
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    if [[ ! -f "$STATE_DIR/password" ]]; then
      (umask 077; openssl rand -hex 16 > "$STATE_DIR/password")
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" \
      -p "$BIND:$PORT:445" \
      -e NAME="$SHARE" -e USER="$SMB_USER" -e PASS="$(cat "$STATE_DIR/password")" -e RW=true \
      "$IMAGE" >/dev/null
    for _ in $(seq 1 30); do
      if docker exec "$NAME" smbclient -L localhost -U "$SMB_USER%$(cat "$STATE_DIR/password")" -m SMB3 >/dev/null 2>&1; then
        print_env
        exit 0
      fi
      sleep 1
    done
    echo "Samba fixture did not become ready" >&2
    docker logs "$NAME" >&2 || true
    exit 1
    ;;
  env)
    print_env
    ;;
  hashes)
    # Server-side SHA-256 of every file on the share (independent of the app).
    docker exec "$NAME" sh -c 'cd /shared && find . -type f -exec sha256sum {} + | sort -k2'
    ;;
  stop)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
    ;;
  *)
    echo "usage: $0 start|env|hashes|stop" >&2
    exit 2
    ;;
esac
