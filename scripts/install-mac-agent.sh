#!/usr/bin/env bash
# Builds the standalone Mac backup companion and installs it outside this
# checkout, under ~/Library/Application Support/FilesBackups/bin.
#
#   scripts/install-mac-agent.sh            # build + copy binary only
#   scripts/install-mac-agent.sh --launchd  # also install the LaunchAgent
#
# It does not configure jobs, start a backup, or touch existing LaunchAgents
# (com.workspace.*). Add a job with `fbbackup-agent add-local-job ...` first.
# FILES_BACKUPS_HOME redirects everything to an isolated fixture directory.
set -euo pipefail
cd "$(dirname "$0")/../Packages/FileCore"

HOME_DIR="${FILES_BACKUPS_HOME:-$HOME/Library/Application Support/FilesBackups}"
swift build -c release --product fbbackup-agent
BIN_DIR="$HOME_DIR/bin"
mkdir -p "$BIN_DIR"
chmod 700 "$HOME_DIR" "$BIN_DIR"
install -m 755 .build/release/fbbackup-agent "$BIN_DIR/fbbackup-agent.new"
mv -f "$BIN_DIR/fbbackup-agent.new" "$BIN_DIR/fbbackup-agent"
echo "Installed $BIN_DIR/fbbackup-agent"

if [[ "${1:-}" == "--launchd" ]]; then
  "$BIN_DIR/fbbackup-agent" install-launchagent
fi
