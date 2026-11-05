#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TMPDIR:-/tmp}/FreeDisplay-ddc-regression"
mkdir -p "$TEST_BUILD"
xcrun swiftc -swift-version 6 -module-cache-path "$TEST_BUILD/module-cache" \
    -import-objc-header "$ROOT/FreeDisplay/FreeDisplay-Bridging-Header.h" \
    "$ROOT/FreeDisplay/Models/DDCDisplayRouting.swift" \
    "$ROOT/FreeDisplay/Services/DDCService.swift" \
    "$ROOT/tests/DDCRoutingRegression.swift" \
    -o "$TEST_BUILD/FreeDisplayDDCRegression"
"$TEST_BUILD/FreeDisplayDDCRegression"
