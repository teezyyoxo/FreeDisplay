# HDR / XDR extra brightness

Compatible displays enable **HDR / XDR brightness** by default. An explicit per-display opt-out is preserved. Enabling the feature makes extra levels available without immediately raising brightness.

The normal range ends at **100%**. There are three extra control levels: **110%, 120%, and 130%**. Sliders snap to these levels, and brightness keys enter/leave them one step at a time. A key press approaching the boundary stops at 100% before the next press enters HDR. The configurable key increment applies to normal brightness only.

The three labels represent control steps across the available HDR range, not measured luminance percentages. 110% uses one third of the currently available extra range, 120% uses two thirds, and 130% uses the full range. Power, temperature and macOS HDR settings can limit actual output without moving the selected step. The slider reserves sixteen normal segments and three HDR segments, with the 100% boundary and HDR stops marked.

FreeDisplay's keyboard HUD shows the display name, percentage, native brightness in orange and HDR steps in blue. The menu slider, HUD, shortcuts, combined control and presets share the same target and scale. An accepted target appears immediately; physical SDR animation never changes that target or interferes with rapid key repeats. The combined slider follows the average of its displays and clamps each target independently.

External HDR displays may require **High Dynamic Range** in macOS System Settings → Displays and an HDR-capable connection/input mode. The Display settings link opens that pane; FreeDisplay does not change the HDR mode automatically. An SDR monitor remains limited to normal brightness. If its brightness mode is Software, the monitor’s own backlight setting still determines the hardware maximum.

## Implementation

- `BrightnessScale` owns control-level normalization, boundary stepping, slider geometry, multiplier mapping and migration from the earlier headroom-percentage scale. New persisted HDR levels use `fd.hdrBrightness.<display UUID>.stepLevel`. Existing opt-outs remain under the same `enabled` key. Presets carry an optional scale version; older HDR percentages are converted on application.
- `BrightnessService` publishes targets synchronously, throttles drag-time hardware writes, flushes the final drag value and prevents late reads from overwriting newer inputs. SDR transitions animate physical writes separately. HDR transitions apply discrete levels directly and never send a VCP value beyond the monitor’s native maximum.
- `HDRBrightnessService` owns two click-through windows: a one-pixel EDR activation patch and a full-screen multiply-composited Metal surface. Extended linear sRGB and floating-point surfaces feed the render-server `multiply` compositing mode through `CALayer.compositingFilter`, so the HDR multiplier applies to the desktop behind the window. Passing a `CIMultiplyCompositing` filter object through the in-process Core Image path did not brighten the desktop even with reported EDR headroom. The multiplier is `1 + (current headroom - 1) × HDR step / 3`.
- A 5 Hz common-mode timer explicitly presents both Metal surfaces, including while menu tracking or dragging is active. Neutral gamma tables are not repeatedly rewritten in the HDR range. GammaService remains the sole owner of transfer-table writes.
- `BrightnessKeyService` intercepts at the head of the login-session event stream, consumes both edges of handled keys and routes them through the same scale. Shortcut recording, disabled routing and unrelated events pass through. Existing Accessibility/Input Monitoring permissions are still required; FreeDisplay does not modify those grants. A common-mode health monitor rebuilds stale taps after permission changes and continues retrying when installation is unavailable. Settings distinguishes an installed monitor from received brightness events, and includes a restart action.
- `BrightnessHUDService` presents non-activating, click-through SwiftUI HUD panels above the brightness overlay on the target display. Its dismissal timer also runs in common modes. The old private OSDUIHelper XPC implementation is removed.
- Returning to 100%, disabling, disconnecting, sleeping or quitting removes the boost. `NSWorkspace.didWakeNotification` recreates surfaces after WindowServer settles. Reconfiguration refreshes capability and geometry. Virtual and mirrored outputs are excluded from independent boosting.

## Verification (2026-10-28)

Run `bash tests/run-brightness.sh` in a macOS desktop session. The regression harness compiles the app’s actual model, brightness/key/HDR services, HUD, slider and design components. Hardware DDC and gamma writes are recorded/stubbed, so panel backlight and calibration are not changed. Real HDR overlay windows and HUD panels appear briefly and are removed on completion. Test preferences are isolated to the harness process and restored.

Checks cover scale round trips, snapping, 100% boundary stepping, saved-level/preset migration, HDR defaults and opt-outs, rapid repeats, event decoding/consumption, physical animation in menu-tracking mode, late readbacks, keyboard/drag HDR levels, software-dimming fallback, mixed-display clamping, and native hardware bounds. The harness also exports HUD/slider renders for visual review to its temporary build directory.

On the connected G32QC A, macOS reported potential headroom above 1, and all three selected HDR levels produced increasing rendered multipliers. The HP 27b Curved reported headroom 1 and retained a 100% limit. This verifies selected rendering state, not panel luminance or color accuracy. It did not establish visible desktop amplification: the initial filter-object compositor passed these assertions while the user saw no increase above 100%. Live physical-key verification after the session-tap correction: the main display changed 120% → 110% with the normal brightness-down key; Option + Brightness Down routed to the HP and changed its target 28% → 21.75%. The user then moved the pointer onto the HP and pressed brightness down/up, confirming that its slider followed and the FreeDisplay HUD appeared instead of the native popup. WindowServer inspection confirmed an enabled session-stage tap with the requested media/key-down/key-up mask. This live test is separate from the stubbed regression harness. After correcting the desktop compositor in build **3CoNW9B**, the user compared the Gigabyte at 100% and 130% and confirmed that HDR is visibly brighter. This visual confirmation is separate from headroom readings and command/multiplier assertions. Protected video, real sleep/wake and cable reconnect remain manual checks.

The Debug app is built using the configured signing identity. macOS may require re-enabling the existing brightness-key permissions when replacing an earlier ad-hoc-signed test build. The version stays **1.0.2**; its changelog entry includes these corrections.

## References

- [Apple: current EDR headroom](https://developer.apple.com/documentation/appkit/nsscreen/maximumextendeddynamicrangecolorcomponentvalue)
- [Apple: event-tap creation](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:))
- [Apple: CALayer compositingFilter](https://developer.apple.com/documentation/quartzcore/calayer/compositingfilter)
- [MaxNits: render-server multiply overlay implementation](https://github.com/yogeshvar/maxnits/blob/main/Sources/MaxNits/OverlayWindow.swift)
- [BetterDisplay: XDR/HDR upscaling methods](https://github.com/waydabber/BetterDisplay/wiki/XDR-and-HDR-brightness-upscaling)

## App timestamps

Finder can show an old modification date for an app bundle directory even when its executable, signature and build hash are current. Packaging refreshes the exported bundle directory date after copying; the build hash remains the authoritative identifier for the executable delivered.
