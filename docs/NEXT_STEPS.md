# Validation and next steps

Snapshot prepared November 12, 2026.

## Current state

Beta. Real-server tests are opt-in and need isolated fixtures; restic is required for backup integration checks. Review retention and restore operations before using real data. Signing assets and backup data are excluded.

## Validation

PASS: Swift package manifest evaluation. Native compilation, transfer/backup integration suites, live storage and device acceptance were not rerun for this publication.

Publication checks: the exact Git tree and its new history are scanned locally with Gitleaks before the repository becomes public. Reviewed scanner exceptions are restricted to synthetic fixture secrets, an invalid test token, a browser preference name and the published NIST AES test vector. Private histories are not included.

## Next action

Follow the README quick start, run the documented focused tests, then use isolated inputs for a manual walkthrough. Real hardware, release signing, background behavior and live-server compatibility are outside this publication check.
