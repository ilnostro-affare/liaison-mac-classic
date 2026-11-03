#!/usr/bin/env bash
# Puts a Swift 5.10 toolchain into a folder WITHOUT root, on Linux (Ubuntu 24.04 containers), so that
# scripts/test-core-linux.sh and scripts/check-escapes.sh can run. SwiftUI/AppKit are never compiled here.
# bash scripts/linux-swift-setup.sh [dir] (default: $TMPDIR/swiftdl or /tmp/swiftdl)
# then:
# export LD_LIBRARY_PATH=<dir>/icu/usr/lib/x86_64-linux-gnu PATH=<dir>/root/usr/libexec/swift/bin:$PATH
# Packages used: swiftlang + libswiftlang 5.10.1-2 (Ubuntu archive), libicu76 76.1-4ubuntu2
# (newer Ubuntu; swiftlang 5.10.1-2 links against ICU 76).
set -euo pipefail
D="${1:-${TMPDIR:-/tmp}/swiftdl}"
mkdir -p "$D" && cd "$D"
POOL=http://archive.ubuntu.com/ubuntu/pool
get() { [ -s "$2" ] || curl -fsSL -o "$2" "$1"; }
apt-get download swiftlang libswiftlang >/dev/null 2>&1 && mv -f swiftlang_*.deb swiftlang.deb && mv -f libswiftlang_*.deb lib.deb || {
  get "$POOL/universe/s/swiftlang/swiftlang_5.10.1-2_amd64.deb" swiftlang.deb
  get "$POOL/universe/s/swiftlang/libswiftlang_5.10.1-2_amd64.deb" lib.deb
}
get "$POOL/main/i/icu/libicu76_76.1-4ubuntu2_amd64.deb" icu.deb
rm -rf root icu && mkdir -p root icu
dpkg-deb -x swiftlang.deb root && dpkg-deb -x lib.deb root && dpkg-deb -x icu.deb icu
echo "export LD_LIBRARY_PATH=$D/icu/usr/lib/x86_64-linux-gnu PATH=$D/root/usr/libexec/swift/bin:\$PATH"
LD_LIBRARY_PATH="$D/icu/usr/lib/x86_64-linux-gnu" "$D/root/usr/libexec/swift/bin/swiftc" --version | head -1
