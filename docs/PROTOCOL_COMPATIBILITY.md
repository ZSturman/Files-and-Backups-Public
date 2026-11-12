# Protocol and device compatibility

Updated October 20, 2026. Only rows marked **tested** have evidence from
this repository's tests or device runs. Everything else is expected to work
through the protocol but is unverified until a row is added here.

## Libraries

| Library | Version | License | Notes |
| --- | --- | --- | --- |
| AMSMB2 + libsmb2 | 4.0.3 (libsmb2 aff9fa6) | LGPL-2.1 / LGPL-2.1+ | **Vendored and patched** (`Packages/Vendor`): request timeouts left callbacks pointing at freed stack memory; any later use of the connection crashed (reproduced on a physical iPhone; stock code also crashes 3/3 under `testServerStallLongerThanTimeoutDoesNotCrash`). Dynamic framework. SMB2/3 only, no SMB1. |
| Citadel (SFTP) | 0.11.1 exact | MIT | 0.12.x was not adopted: it depends on a swift-nio-ssh fork published by an unrelated account. 0.11.1 uses the Citadel maintainer's own fork. |
| restic (companion) | 0.19.1 (Homebrew) | BSD-2 | Invoked as a separate process; not linked. |

Library behaviors handled in the providers:

- SMB: libsmb2 needs backslash separators for listing/rename; every connect
  failure surfaces as `EPERM`, so the provider probes TCP first and lists
  shares to tell unreachable / bad credentials / missing share apart;
  AMSMB2's recursive delete mangles non-ASCII paths, so the provider walks
  trees itself. Manifest names are normalized to NFC.
- WebDAV: URLSession owns the `Authorization` header, so credentials are
  answered through a challenge delegate (Basic and Digest). No partial
  writes: interrupted files restart; publication uses `MOVE` + `Overwrite: F`.
- SFTP: exclusive create uses `SSH_FXF_EXCL`; writes are split at 255 KiB;
  host keys are pinned at setup (SHA256 fingerprint shown) and a changed key
  is refused.

## Tested combinations

| Server | Client | Route | Result |
| --- | --- | --- | --- |
| Samba 4.23.10 (container, 127.0.0.1) | macOS `swift test` (10 tests) | loopback | **Tested**: browse, Unicode, exclusive create, offset write, no-replace rename, nested upload with interruption + resume, SHA-256 read-back, wrong password, unreachable, missing share/root, required SMB3 encryption, share list, 9 s server freeze longer than the timeout |
| Samba 4.23.10 (container bound to the Mac's Tailscale IP) | **iPhone 16 Pro Max (physical)**, app UI | Tailscale | **Tested** repeatedly: Add Storage → Test Connection → browse → nested 48 MB folder upload; 45 s server stall mid-upload; app sent to background mid-transfer and reopened; app terminated mid-transfer and relaunched; second upload kept both (`FB Acceptance (2)`); all 10 files matched by server-side SHA-256, no temp files left |
| Same | **iPad Pro 12.9" 5th gen (physical)**, app UI | Tailscale | **Tested**: same flow, all 10 files matched by server-side SHA-256 |
| Same (127.0.0.1) | iPhone 17 Pro Simulator, app UI | loopback | **Tested**: Add Storage flow, upload, server hashes |
| Apache httpd mod_dav (`bytemark/webdav`, Basic) | macOS `swift test` (5 tests) | loopback HTTP | **Tested**: browse, Unicode/`&`/`#` names, MKCOL conflict, MOVE without overwrite, nested upload keep-both + SHA-256 read-back, wrong password, unreachable |
| OpenSSH (`linuxserver/openssh-server`) | macOS `swift test` (6 tests) | loopback | **Tested**: pinned host key + mismatch refused, exclusive create, no-replace rename, interrupted upload resumed from offset + SHA-256 read-back, wrong password, unreachable |
| **Home Services v1 (live, Pi `pi.example.local`, server 0.3.0, contract 1.1)** | macOS `swift test` (`HomeServicesLiveTests`) | Tailscale HTTPS | **Tested**: bootstrap/contract check, single-entry lookup (1.1; listing fallback on 1.0), capabilities, capacity, nested upload via resumable sessions with server SHA-256, keep-both, no-overwrite move, snapshots, protection, Trash |
| Home Services v1 stub (contract shapes) | `swift test` (7 tests) | URLProtocol | **Tested**: pagination, error envelope, offset mismatch, volume-unavailable retry, 1.0 listing fallback, Trash/restore, snapshot entries, restore jobs |
| **Home Services v1 (live)** | **iPhone 16 Pro Max and iPad Pro 12.9" (physical)**, app UI | home network + Tailscale | **Tested**: add, 20 MB upload, preview, rename, move, Trash + restore, protection, snapshot browsing; server-side hashes match |
| **Home Services v1 (live)** | **iPhone on cellular, away from home** | Tailscale over cellular | **Tested** (2 MB fixture): same flow; hashes match |
| Samba container on the Mac's Tailscale IP | iPhone on cellular, relayed Tailscale path | Tailscale (DERP) | **Inconclusive**: transfer, stall and resume completed; UI test timed out |
| Samba 4.23.10 (127.0.0.1) | **this MacBook Pro**, Mac app UI tests | loopback | **Tested**: add, upload, browse, file detail, rename; companion status readable in the sandboxed app |

## Not yet tested

| Combination | Status |
| --- | --- |
| macOS File Sharing (this Mac's shares) | Not written to: they expose the live workspace. Use a disposable share if you want this row. |
| Windows 10/11 SMB share | No Windows device available. |
| Raspberry Pi Samba on real hardware | The Pi's only SMB share is the read-only restic view; not used. |
| NAS (Synology/QNAP/…) | No NAS available. |
| WebDAV over HTTPS on a real server; Digest auth | Only the loopback HTTP fixture. |
| SFTP to a real host from a physical device | Only the loopback fixture. |
| Share Extension on a device | Builds, signs, and installs; the share-sheet flow needs a manual check (see NEXT_STEPS). |
