// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FileCore", targets: ["FileCore"]),
        .library(name: "FileCoreSMB", targets: ["FileCoreSMB"]),
        .library(name: "FileCoreSFTP", targets: ["FileCoreSFTP"]),
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "fbbackup-agent", targets: ["FilesBackupsAgent"]),
    ],
    dependencies: [
        // AMSMB2 4.0.3 vendored with a timeout use-after-free fix (see
        // Packages/Vendor/README.md). LGPL-2.1; built as a dynamic library.
        .package(path: "../Vendor/AMSMB2"),
        // SFTP client (MIT). 0.11.1 is pinned because 0.12.x switched to a
        // swift-nio-ssh fork published by an unrelated account; 0.11.1 uses
        // the Citadel maintainer's own fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.11.1"),
    ],
    targets: [
        // Provider contracts, paths, credentials, connection profiles, staging,
        // and the persistent transfer queue. No third-party dependencies.
        .target(name: "FileCore"),
        // Direct SMB2/3 provider. libsmb2 never negotiates SMB1.
        .target(
            name: "FileCoreSMB",
            dependencies: [
                "FileCore",
                .product(name: "AMSMB2", package: "AMSMB2"),
            ]
        ),
        // Direct SFTP provider with pinned host keys.
        .target(
            name: "FileCoreSFTP",
            dependencies: [
                "FileCore",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        // Backup schedule, job status, restic invocation, and restore checks.
        .target(name: "BackupCore"),
        // Standalone Mac backup companion (installed outside the checkout).
        .executableTarget(
            name: "FilesBackupsAgent",
            dependencies: ["BackupCore"]
        ),
        .testTarget(name: "FileCoreTests", dependencies: ["FileCore"]),
        .testTarget(name: "FileCoreSMBTests", dependencies: ["FileCore", "FileCoreSMB"]),
        .testTarget(name: "FileCoreSFTPTests", dependencies: ["FileCore", "FileCoreSFTP"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
    ]
)
