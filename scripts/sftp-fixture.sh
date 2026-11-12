#!/usr/bin/env bash
# Disposable OpenSSH SFTP fixture (linuxserver/openssh-server) on 127.0.0.1.
#   scripts/sftp-fixture.sh start|env|stop
set -euo pipefail
NAME="files-backups-sftp-fixture"
IMAGE="lscr.io/linuxserver/openssh-server:latest"
PORT="${FB_SFTP_FIXTURE_PORT:-4422}"
STATE_DIR="${TMPDIR:-/tmp}/$NAME"
USER_NAME="fixture"

print_env() {
  echo "export FB_SFTP_TEST_HOST=127.0.0.1"
  echo "export FB_SFTP_TEST_PORT=$PORT"
  echo "export FB_SFTP_TEST_USER=$USER_NAME"
  echo "export FB_SFTP_TEST_PASSWORD=$(cat "$STATE_DIR/password")"
  echo "export FB_SFTP_TEST_ROOT=/config/files"
}

case "${1:-}" in
  start)
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    [[ -f "$STATE_DIR/password" ]] || (umask 077; openssl rand -hex 16 > "$STATE_DIR/password")
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:2222" \
      -e PUID=1000 -e PGID=1000 -e PASSWORD_ACCESS=true -e USER_NAME="$USER_NAME" \
      -e USER_PASSWORD="$(cat "$STATE_DIR/password")" "$IMAGE" >/dev/null
    for _ in $(seq 1 60); do
      if docker exec "$NAME" sh -c 'nc -z 127.0.0.1 2222' >/dev/null 2>&1 && docker logs "$NAME" 2>&1 | grep -q "Server listening\|done"; then
        docker exec "$NAME" sh -c "mkdir -p /config/files && chown 1000:1000 /config/files"
        print_env; exit 0
      fi
      sleep 1
    done
    echo "SFTP fixture did not become ready" >&2; docker logs "$NAME" >&2; exit 1 ;;
  env) print_env ;;
  rotate-host-key)
    # Simulates a server whose identity changed (for pinning tests).
    docker exec "$NAME" sh -c 'rm -f /config/ssh_host_keys/ssh_host_* && ssh-keygen -A -f /config >/dev/null 2>&1 || true'
    docker restart "$NAME" >/dev/null ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$STATE_DIR" ;;
  *) echo "usage: $0 start|env|stop" >&2; exit 2 ;;
esac
