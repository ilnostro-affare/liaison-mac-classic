#!/usr/bin/env bash
# Fails on a doubled backslash in Swift outside raw strings (#"..."#). It compiles in no form that is
# intended: "\\(x)" prints a backslash instead of interpolating, and \\.key is a syntax error.
# A settings screen once shipped with both and the release build failed.
set -euo pipefail
cd "$(dirname "$0")/.."
hits=$(grep -rn '\\\\[.(n]' App Shared --include=*.swift | grep -v '#"' | grep -v 'escape-ok' || true)
if [ -n "$hits" ]; then echo "$hits"; echo "doubled backslash found"; exit 1; fi
echo "escapes ok"

# Syntax parse of every Swift file (no SDK needed). Catches what broke the build above before it reaches
# Xcode; type errors in SwiftUI code still need Xcode. SWIFTC can wrap a toolchain (chroot, docker).
if command -v "${SWIFTC:-swiftc}" >/dev/null 2>&1; then
  fail=0
  for f in $(find App Shared Tests -name '*.swift'); do
    out=$(${SWIFTC:-swiftc} -parse "$f" 2>&1 | grep 'error:' || true)
    if [ -n "$out" ]; then echo "$out"; fail=1; fi
  done
  [ "$fail" = 0 ] && echo "parse ok" || { echo "syntax errors"; exit 1; }
fi
