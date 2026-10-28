#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="${TMPDIR:-/tmp}/FreeDisplay-brightness-regression"
mkdir -p "$TEST_BUILD" "$TEST_BUILD/rendered"
xcrun swiftc -swift-version 6 -module-cache-path "$TEST_BUILD/module-cache" \
    "$ROOT/FreeDisplay/Models/BrightnessScale.swift" \
    "$ROOT/FreeDisplay/Models/DisplayInfo.swift" \
    "$ROOT/FreeDisplay/Models/DisplayPreset.swift" \
    "$ROOT/FreeDisplay/Models/ShortcutBinding.swift" \
    "$ROOT/FreeDisplay/Utilities/NSScreenExtension.swift" \
    "$ROOT/FreeDisplay/Services/BrightnessService.swift" \
    "$ROOT/FreeDisplay/Services/HDRBrightnessService.swift" \
    "$ROOT/FreeDisplay/Services/BrightnessKeyService.swift" \
    "$ROOT/FreeDisplay/Services/BrightnessHUDService.swift" \
    "$ROOT/FreeDisplay/Views/BrightnessSliderView.swift" \
    "$ROOT/FreeDisplay/Views/BrightnessHUDView.swift" \
    "$ROOT/FreeDisplay/Views/Design/GlassStyle.swift" \
    "$ROOT/tests/BrightnessRegression.swift" \
    -o "$TEST_BUILD/FreeDisplayBrightnessRegression"
FD_TEST_RENDER_DIR="$TEST_BUILD/rendered" "$TEST_BUILD/FreeDisplayBrightnessRegression"
