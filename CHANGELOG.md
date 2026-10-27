# Changelog

All notable changes to FreeDisplay are documented here.

---

## v1.0.1 (2026-10-27)

- Fix menu content sizing so display controls, tools, and settings remain visible.
- Expand the menu panel and add an adjustable blurred background.
- Add separate continuous blur-strength and background-opacity controls.
- Add configurable keyboard brightness routing for the external display under the pointer, including an adjustable per-press step and Accessibility permission status.
- Fix active ICC profile readback and verify profile changes before showing them as applied.
- Route brightness keys using the cursor’s containing display and show the last routed display.
- Make the background slider control transparency and strengthen the independent blur effect.
- Improve menu spacing, section hierarchy, display-aware sizing, and icon color restraint.
- Report Accessibility and Input Monitoring requirements for brightness-key routing.
- Fix a crash when adjusting brightness on a DDC-capable external display from the slider or keyboard; the DDC completion handler was main-actor isolated but ran on the DDC queue.
- Fix brightness keys falling through to macOS, which only adjusted the primary display, when the pointer was on a DDC display; the crash above killed the key handler.
- Enlarge menu icons.
- Adopt Liquid Glass on macOS 26 and later, keeping the blur background on earlier releases.
- Add a System/Light/Dark appearance selector to Settings.
- Return intercepted key events unretained from the event tap to stop leaking them.
- Handle keyboards that send brightness as F14/F15 key presses instead of media-key events, which is why brightness keys never reached the display under the pointer.
- Build HiDPI overrides from the panel's unrotated orientation so rotated displays get usable HiDPI modes, and write each override through a unique temp file.
- Fix the display mode list being empty on portrait displays, tag each resolution Native or HiDPI, and tell the user when a HiDPI override needs the display reconnected.
- Remove the built-in Native/HiDPI preset toggle; only user-saved presets remain.
- Ask for confirmation before making a display the main display.
- Add configurable shortcuts for brightness on the primary display, the secondary display, both displays, and a sync that matches the secondary to the primary. They override pointer-based control and are set in Settings.
- Redesign the menu panel with Liquid Glass cards, per-display brightness on each card, tinted glass icons, and a continuous glass slider.
- Move settings into their own window with General, Brightness Keys, Shortcuts, Appearance, and About pages.
- Stamp a new random build hash into every build, including Debug, so the version always shows a hash instead of "DEV".
- Display a unique seven-character build identifier next to the app version.
- Translate user-facing app text to English.
- Translate remaining Chinese comments in the source and remove the unused screen-recording permission string.

## v1.0.0 (2026-03-05)

Initial public release — full-featured BetterDisplay alternative.

### Core Features

- **Display Detection & Menu Bar UI** (Phase 1)
  - Multi-monitor detection (built-in + external)
  - MenuBarExtra-based UI with per-display panels
  - Display identification (visual flash)

- **DDC Brightness & Contrast Control** (Phase 2)
  - IOKit I2C DDC/CI communication
  - Hardware brightness and contrast sliders for external monitors
  - Software gamma brightness for built-in displays

- **Resolution Management & HiDPI** (Phase 3)
  - Resolution list with HiDPI/native/scaled modes
  - HiDPI virtual display creation (CGVirtualDisplay)
  - Resolution slider for quick switching

- **Rotation & Arrangement** (Phase 4)
  - Display rotation: 0°/90°/180°/270°
  - Visual display arrangement editor

- **Color Management** (Phase 5)
  - ICC color profile switching per display
  - Color mode display (8-bit/10-bit, SDR/HDR)

- **Image Adjustment** (Phase 6)
  - Software contrast, gamma, color temperature
  - Per-channel RGB gain control
  - Color inversion

- **Advanced Display Management** (Phase 7)
  - Set primary display
  - Display info panel (resolution, refresh rate, vendor)

- **Screen Mirroring** (Phase 8)
  - Mirror any display to any other display
  - Mirror enable/disable toggle

- **Screen Streaming & Picture-in-Picture** (Phase 9)
  - ScreenCaptureKit-based screen capture
  - Floating PiP window with configurable size and position
  - Stream controls: flip, rotate, scale, crop, opacity, video filters

- **Virtual Display** (Phase 10)
  - Create HiDPI virtual/dummy displays
  - Useful for headless Macs or extending workspace

- **Config Protection & Auto Brightness** (Phase 11)
  - Prevent macOS from resetting display configuration
  - Time-based auto brightness scheduling

- **Notch Management** (Phase 12)
  - Notch overlay show/hide for MacBooks with notch

### Stability & Polish

- **Critical Bug Fixes** (Phase 13)
  - DDC communication reliability improvements
  - CoreGraphics API usage corrections

- **Performance Optimization** (Phase 14)
  - Async display enumeration
  - Reduced UI blocking on IOKit calls

- **UX Improvements** (Phase 15)
  - Improved slider responsiveness
  - Better error states and user feedback

- **Comprehensive Bug Fixes — 134 bugs** (Phase 16)
  - 5 rounds of systematic bug fixing across all features
  - 3 rounds of UI/UX polish
  - Unified hover effects across all views
  - Extracted reusable components: DetailRow, ExpandableRow, ProtectionRowView
  - DisplayDetailView three-group layout
  - Rotation 2×2 grid layout
  - ArrangementView interior/exterior display thumbnail distinction
  - DisplayModeList favorites pinned to top
  - ConfigProtection active protection badge

- **DDC / HiDPI / Notch Targeted Fixes** (Phase 17)
  - CGVirtualDisplay: vendorID must be non-zero
  - CGVirtualDisplay must be created on main thread
  - Bridging header property name corrections
  - One-click display presets completed

- **CG Timeout Protection + Wake Recovery** (Phase 18)
  - CoreGraphics call timeout protection
  - Sleep/wake display state recovery
  - GammaService wake notification handler
  - BrightnessService wake reapplication

### Preset System

- **Display Preset One-Click Switching** (Phase 19)
  - Save full display configuration as named preset
  - Instant restore: resolution, brightness, rotation, color profile
  - Preset management UI (create, rename, delete)

### Release

- **App Icon, DMG Packaging, Launch at Login** (Phase 20)
  - App icon: gradient blue-purple monitor with "F" lettermark
  - DMG installer with Applications shortcut
  - SMAppService-based launch at login (macOS 13+)
  - README, CHANGELOG, release automation script
  - UpdateService pointing to GitHub Releases API
