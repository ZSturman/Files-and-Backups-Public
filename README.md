# Files & Backups

Independent native file-transfer and backup clients with resumable operations, provider adapters and recovery checks.

**Status:** Beta. Real-server tests are opt-in and need isolated fixtures; restic is required for backup integration checks. Review retention and restore operations before using real data. Signing assets and backup data are excluded.

[Project portfolio](https://zacharysturman.com/projects/files-backups)

## Quick start

```sh
xcodegen generate
open FilesBackups.xcodeproj
```

## Usage

Open the FilesBackups scheme in Xcode, choose your destination, configure your signing team and run.

## How it works

Swift packages separate file providers, transfer state and backup coordination from the interface. SMB, SFTP, WebDAV and optional Home Services integrations have distinct capabilities. The Mac backup companion runs independently.

## Testing

```sh
swift test --package-path Packages/FileCore
```

See [validation and next steps](docs/NEXT_STEPS.md) for the checks performed on this snapshot. Automated fixture tests do not establish physical-device compatibility.

## Configuration and privacy

This is a curated source snapshot, published November 12, 2026. Configure your own endpoints, credentials and signing identities. Private development history, local environment files, personal recordings, runtime databases, signing materials and deployment automation are excluded. Deployment and device installation are explicit operator actions.

## Further reading

- [Protocol Compatibility](docs/PROTOCOL_COMPATIBILITY.md)
- [Backup Strategy](docs/BACKUP_STRATEGY.md)

## License and attribution

Existing licenses and third-party notices apply to the files they cover. Publication of this snapshot does not grant a new license to original material; no additional license is granted where none is supplied.
