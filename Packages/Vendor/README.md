# Vendored dependencies

## AMSMB2 4.0.3 (LGPL-2.1) with libsmb2 (LGPL-2.1-or-later)

Source: https://github.com/amosavian/AMSMB2/tree/4.0.3 with the libsmb2
submodule at aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03. Vendored so the
crash fix below ships; everything else is unmodified upstream source.

Modifications (see `AMSMB2-4.0.3-timeout-use-after-free.patch`):

1. `AMSMB2/Context.swift`, `wait_for_reply`: when a request times out the
   connection is destroyed instead of being reused. Upstream leaves the
   timed-out request queued in libsmb2 with pointers into the caller's stack
   (CBData, read buffers, stat structs); any later servicing of that
   connection, including `disconnect()`, let a late reply write into freed
   memory. Reproduced on a physical iPhone 16 Pro Max: a 45 s server stall
   during an upload crashed with EXC_BAD_ACCESS in libsmb2 `open_cb` under
   `SMB2Client.disconnect()`. Regression test:
   `SMBProviderIntegrationTests.testServerStallLongerThanTimeoutDoesNotCrash`.
2. `Package.swift`, `Package@swift-6.0.swift`: removed the AMSMB2Tests test
   target and its swift-atomics dependency (tests are not vendored).

Not yet reported upstream (as of October 20, 2026); upstream `main` has the
same code. Remove this vendored copy once a fixed release exists.
