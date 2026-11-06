# Changelog

All notable changes to FreeDisplay are documented here.

---

## v1.1.1a (2026-11-06)

- Extend external displays' low-brightness range with software dimming below 20%, retaining a small visibility floor and restoring the chosen level after reconnect.
- Hold Shift with brightness keys or display shortcuts for 1% steps through 100%; explicitly configured shortcuts take precedence.
- Retry external-display DDC brightness after a failed read or write, so a temporary software fallback cannot leave the monitor's hardware backlight stuck low at 100%.
- Clear stale software dimming when hardware brightness is detected, regardless of startup ordering, and ignore reads superseded by newer hardware writes.
- Add regression coverage for DDC recovery and saved software-dimming restoration. Verify the HP 27b recovers from a simulated routing failure and reads back 50% and 100% hardware brightness (initially 6%).

## v1.1.0 (2026-11-05)

- Fix G32 controls changing the HP secondary monitor while leaving the G32 at full brightness. Match each DDC endpoint to its named framebuffer port and a unique physical display identity; remove enumeration-order and vendor/model fallback assignments.
- Use per-display software dimming when hardware identity is missing or ambiguous, instead of risking a command to another monitor. Validate DDC reply framing, result, command echo, checksum, and brightness range.
- Rebuild routing on display reconfiguration and wake, cancel queued commands from older configurations, and ignore stale brightness callbacks. Replace display models when macOS reuses an ID for another physical monitor.
- Release DDC connections after each transaction. Save software dimming by display UUID, disregard unsafe legacy ID-only factors, and clear leftover software dimming after a successful hardware adjustment.
- Register wake recovery when the display manager starts, so recovery works before the menu is opened.
- Add regression coverage for the captured G32/HP routing failure, reversed enumeration, unavailable/ambiguous endpoints, reused IDs, invalid replies, queue cancellation, and late callbacks. Verify G32 hardware brightness changes independently of HP on the connected monitors.
- Make built-in brightness changes immediate: set brightness through DisplayServices (loaded at runtime, IOKit fallback) instead of the IOKit parameter that triggers a multi-second system fade. Apply key and preset changes directly with no ramp, and shorten the slider write throttle to 10 ms.
- Coalesce queued DDC brightness writes per display so only the newest value is sent; previously every step queued behind a full IORegistry routing scan, delaying external-monitor changes by seconds.

## v1.0.2 (2026-10-28)

- Enable HDR / XDR brightness by default on compatible displays while preserving explicit per-display opt-outs.
- Use three HDR control steps at 110%, 120%, and 130%, mapped across the currently available extra brightness, instead of exposing theoretical headroom as a misleading continuous percentage range.
- Fix HDR activating and showing higher percentages without brightening the desktop: use render-server multiply compositing instead of an in-process Core Image filter object; verify visible improvement against native 100%.
- Keep sliders, keyboard controls, combined adjustments, and presets on the same scale, with a clear 100% boundary and HDR step markers.
- Fix slider readback after keyboard changes, rapid key-repeat accumulation, and dragging into HDR; publish targets immediately and prevent late hardware reads from overwriting newer adjustments.
- Replace the native brightness HUD with a FreeDisplay HUD showing the display name, percentage, normal brightness bar, and three blue HDR steps. Consume handled brightness keys in the login-session event stream before macOS processes them.
- Keep brightness animation, HDR rendering, and HUD dismissal active while menus and sliders are being tracked.
- Fix lost physical media-key input caused by using a HID-stage tap; restore live slider/HUD updates, secondary-display shortcuts, and pointer-based brightness routing with a session-stage tap.
- Recover the keyboard monitor after permission changes or disabled/invalid taps without a fixed retry cutoff; show received brightness-event counts and provide a restart control in Settings.
- Refresh exported app-bundle timestamps so Finder reflects the newly delivered build instead of an older directory date.
- Save HDR preferences per display, migrate earlier saved HDR percentages and presets to the stepped scale, and restore the boost after relaunch, reconnect, and wake; remove overlays when disabled, at 100% or below, on disconnect, sleep, and quit.
- Route software dimming through GammaService to preserve image adjustments, and avoid redundant hardware brightness writes in the HDR range.

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
