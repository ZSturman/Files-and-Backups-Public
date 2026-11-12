# Backup strategy for ~/Workspace (recommendation)

October 21, 2026. Based on measured sizes and the current setup. Owner
decisions are marked **Decide**.

**Applied October 23 (owner-approved):** one job, `mac-workspace`, for all
of `~/Workspace` in the existing repository (instead of item 2's
`mac-workspace-rest`; same deduplication, one schedule, one consistent
daily snapshot), with the exclusions in `scripts/mac-workspace-excludes.txt`
plus `--exclude-caches` and `.nobackup` markers. `mac-projects` is disabled,
reporting to Home Services is on, and the predecessor agents (item 7) are
unloaded. See NEXT_STEPS.md. Items 3–6 still apply.

## What exists today

| Source | Size | Protected by | State |
| --- | --- | --- | --- |
| `~/Workspace/Projects` (excluding `node_modules`, `.build`, `DerivedData`, `.venv`, `__pycache__`) | ~115 GB scanned | Companion job `mac-projects` → restic repo `pi.example.local:/mnt/workspace-backup/files-backups/mac-projects` | Verified: snapshot `af8c64be`, restores hash-matched, `restic check` clean |
| Rest of `~/Workspace` (Assets 61 GB, To Organize 49 GB, Logs 9.7 GB, Review 2.9 GB, smaller) | ~126 GB | Nothing current (predecessor `mac-workspace` snapshot from Sept 9 in `restic-repo`) | **Unprotected since Sept 9** |
| Excluded caches (~63 GB) | — | Not backed up (regenerable) | By design |

## Recommendation

1. **Keep `mac-projects` daily at 02:00** with the current excludes. With
   catch-up after wake/reconnect, retries (15/30/60 min) and the 26 h overdue
   warning, daily is sufficient for code that also lives in Git.
2. **Add a second job, `mac-workspace-rest`**, for the rest of `~/Workspace`,
   written to the **same repository** (deduplication across both jobs):
   `--source ~/Workspace --exclude Projects --exclude Logs --exclude Temporary`
   plus the cache excludes, daily at 03:00. Run its first (~115 GB) upload on
   the home network. **Decide** whether `Logs` (9.7 GB) needs protection.
3. **Retention** (once two or more weeks of history exist): keep 14 daily,
   8 weekly, 12 monthly per job. Always review `fbbackup-agent
   retention-preview` first; pruning is not automated by the companion and
   must stay with the companion (the repository's only writer).
4. **Integrity**: the companion now runs a read-only `restic check` with a 2%
   data read-back weekly after a successful unattended run. Do a manual
   `check --read-data-subset 10%` monthly and a test restore of one project
   quarterly.
5. **A second copy.** Everything (old and new repositories) sits on one
   exFAT HDD on the Pi. That is one copy, one disk, one place. **Decide** on
   an offsite or second-disk copy, e.g. `restic copy` to a rotated external
   disk or a cloud bucket. This is the largest remaining risk.
6. **Network**: the Pi is on Wi-Fi only; an Ethernet cable makes the long
   SFTP sessions more reliable (one 114 GB run was interrupted by a network
   blip before the retry completed it). Unattended runs wait while the Mac is
   on a hotspot or in Low Data Mode (`allowMeteredNetworks` overrides).
7. **Retire the predecessor** `com.workspace.mac-restic-backup` and
   `restic-status-monitor` LaunchAgents once `mac-workspace-rest` has a
   verified snapshot. Keep the old `restic-repo` `mac-workspace` series
   read-only for history; do not prune it until you decide.

## Responsibilities (agreed with the Home Services session)

| Concern | Owner |
| --- | --- |
| Mac backup scheduling, restic writer, repositories under `files-backups/` | Files & Backups companion |
| Retention/prune of a repository | Its writer (companion for `files-backups/*`; nothing prunes `restic-repo` during migration) |
| Pi-local snapshots, `restic-repo` visibility, restore jobs, readiness, ntfy alerts | Home Services |
| Alerts for companion repositories | Home Services via opt-in status-only reports (`fbbackup-agent enable-reporting`); the repository password never leaves the Mac |
| Browsing/restore on iPhone/iPad | App, through Home Services' API (`restic-repo` only) |
