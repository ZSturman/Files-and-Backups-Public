#!/usr/bin/env bash
# Disposable WebDAV fixture (Apache httpd mod_dav, Basic auth) on 127.0.0.1.
#   scripts/webdav-fixture.sh start|env|stop
set -euo pipefail
NAME="files-backups-webdav-fixture"
IMAGE="bytemark/webdav:latest"
PORT="${FB_WEBDAV_FIXTURE_PORT:-4480}"
STATE_DIR="${TMPDIR:-/tmp}/$NAME"
USER_NAME="fixture"

print_env() {
  echo "export FB_WEBDAV_TEST_URL=http://127.0.0.1:$PORT/"
  echo "export FB_WEBDAV_TEST_USER=$USER_NAME"
  echo "export FB_WEBDAV_TEST_PASSWORD=$(cat "$STATE_DIR/password")"
}

case "${1:-}" in
  start)
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
    [[ -f "$STATE_DIR/password" ]] || (umask 077; openssl rand -hex 16 > "$STATE_DIR/password")
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "127.0.0.1:$PORT:80" \
      -e AUTH_TYPE=Basic -e USERNAME="$USER_NAME" -e PASSWORD="$(cat "$STATE_DIR/password")" "$IMAGE" >/dev/null
    for _ in $(seq 1 30); do
      code="$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$(cat "$STATE_DIR/password")" -X PROPFIND -H 'Depth: 0' "http://127.0.0.1:$PORT/" || true)"
      if [[ "$code" == "207" ]]; then print_env; exit 0; fi
      sleep 1
    done
    echo "WebDAV fixture did not become ready" >&2; docker logs "$NAME" >&2; exit 1 ;;
  env) print_env ;;
  stop) docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$STATE_DIR" ;;
  *) echo "usage: $0 start|env|stop" >&2; exit 2 ;;
esac
