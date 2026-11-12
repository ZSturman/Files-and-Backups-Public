#!/usr/bin/env bash
# Regenerates THIRD_PARTY_NOTICES.md (repository) and the in-app
# Acknowledgements resource from the resolved Swift packages. Run after any
# dependency change: scripts/update-licenses.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PKG=Packages/FileCore
(cd "$PKG" && swift package resolve >/dev/null)
OUT=THIRD_PARTY_NOTICES.md
RES=App/Resources/Acknowledgements.txt
mkdir -p App/Resources

python3 - "$PKG" "$OUT" "$RES" <<'EOF'
import json, os, subprocess, sys
pkg, out, res = sys.argv[1:4]
pins = json.load(open(os.path.join(pkg, "Package.resolved")))["pins"]
checkouts = os.path.join(pkg, ".build", "checkouts")
dirs = {d.lower(): d for d in os.listdir(checkouts)}
# Test-only dependencies are not shipped in the app.
test_only = {"swift-atomics"}

def license_file(path):
    for name in sorted(os.listdir(path)):
        if name.lower().startswith(("license", "copying", "licence")):
            return os.path.join(path, name)
    return None

sections = []
header = """# Third-party notices

Files & Backups includes the following open-source software. Versions are
pinned in Packages/FileCore/Package.resolved.

## LGPL notice (AMSMB2 and libsmb2)

AMSMB2 (LGPL-2.1) and the libsmb2 library it contains (LGPL-2.1-or-later)
are shipped as a separate dynamic framework, `Frameworks/AMSMB2.framework`,
which the app links against dynamically. AMSMB2 is **modified**: one change
in `AMSMB2/Context.swift` fixes a crash after request timeouts. The complete
corresponding source of the shipped library, the patch, and a description of
the change are in this repository under `Packages/Vendor/` (README.md and
AMSMB2-4.0.3-timeout-use-after-free.patch). Upstream sources:

- AMSMB2 4.0.3: https://github.com/amosavian/AMSMB2/tree/4.0.3
- libsmb2 at the revision AMSMB2 4.0.3 pins ({LIBSMB2}):
  https://github.com/sahlberg/libsmb2/tree/{LIBSMB2}

You may modify these libraries and rebuild the app against your modified
version: the app's own source is available from the project owner on
request, and the package manifest builds AMSMB2 as a replaceable dynamic
library. Contact: the app's support address listed with the distribution.
"""
vendor = os.path.join(os.path.dirname(pkg), "Vendor", "AMSMB2")
libsmb2_rev = "aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03"
pins = [{"identity": "amsmb2", "location": "https://github.com/amosavian/AMSMB2 (vendored, modified: Packages/Vendor)",
         "state": {"version": "4.0.3"}, "path": vendor}] + pins
header = header.replace("{LIBSMB2}", libsmb2_rev)

for pin in sorted(pins, key=lambda p: p["identity"]):
    ident = pin["identity"]
    if ident in test_only:
        continue
    path = pin.get("path") or os.path.join(checkouts, dirs.get(ident, ident))
    version = pin["state"].get("version") or pin["state"].get("revision", "")[:12]
    lic = license_file(path)
    text = open(lic, encoding="utf-8", errors="replace").read().strip() if lic else "(license file not found)"
    sections.append(f"## {ident} {version}\n\n{pin['location']}\n\n```\n{text}\n```\n")
    for name in sorted(os.listdir(path)):
        if name.upper().startswith("NOTICE"):
            notice = open(os.path.join(path, name), encoding="utf-8", errors="replace").read().strip()
            sections.append(f"### {ident} {name}\n\n```\n{notice}\n```\n")
    if ident == "amsmb2":
        sub = os.path.join(path, "Dependencies", "libsmb2")
        for name in ("COPYING", "LICENCE-LGPL-2.1.txt"):
            p = os.path.join(sub, name)
            if os.path.exists(p):
                sections.append(f"## libsmb2 ({name}) {libsmb2_rev}\n\nhttps://github.com/sahlberg/libsmb2\n\n```\n{open(p, encoding='utf-8', errors='replace').read().strip()}\n```\n")

doc = header + "\n" + "\n".join(sections)
open(out, "w").write(doc)
open(res, "w").write(doc.replace("```\n", "").replace("```", ""))
print(f"wrote {out} and {res} ({len(sections)} sections)")
EOF
