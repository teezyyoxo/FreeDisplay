# Brightness routing repair — 1.1.0

On November 5, 2026, the G32QC A slider and keys changed the HP 27b Curved's backlight, while the G32 remained at 100%. HDR amplification still targeted G32 correctly because it used its NSScreen directly. The HUD and target percentage therefore appeared correct despite the hardware route being swapped.

The captured topology had CG IDs G32=2 and HP=3, but AV endpoint order HP first, G32 second. Neither AV proxy's ancestors contained the vendor/product properties the old matcher expected. The index fallback assigned HP's endpoint to ID 2. A read-only reproduction returned 57% for ID 2 and 100% for ID 3, the reverse of the physical monitors.

The new route joins the AV endpoint's explicitly named port (for example, `dispext1:dcpav-service-epic:0`) to the matching framebuffer parent (`dispext1`). The framebuffer's `DisplayAttributes.ProductAttributes` identifies the panel. A unique name/serial match against main-actor display snapshots is required in both directions. The monitors share numeric serial 16843009; serial alone cannot distinguish them. There is no enumeration-order, vendor/model, or remaining-service fallback. Unknown or ambiguous identity falls back to GammaService on the requested display.

Registry identity properties are also used by [MonitorControl's ARM64 DDC implementation](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift). FreeDisplay retains its existing IOAVService APIs and adds no private API or dependency.

Connections are acquired and released per transaction. Display reconfiguration immediately invalidates queued work; completed callbacks cannot update a newer display session. Full refresh detects reused display IDs. DDC replies must have valid framing, status, command echo, checksum and value range. Software factors use physical display UUIDs; legacy ID-only factors are not restored because their original identity cannot be proven. Successful hardware writes remove residual software dimming while preserving image adjustments.

DisplayManager registers wake recovery at initialization. After WindowServer settles it rebuilds identities and reapplies brightness, gamma and saved modes, without requiring the menu to have been opened first.

## Verification

- `bash tests/run-ddc-routing.sh`: real matcher/parser/async DDC queue, including the captured reversed G32/HP topology, all input permutations, missing/duplicate ports, duplicate monitors, conflicting serials, reused IDs, malformed replies and cancellation completion. No hardware writes.
- `bash tests/run-brightness.sh`: app brightness, key, slider, HUD and HDR paths with stubbed hardware; includes callbacks completing after session invalidation. Requires a desktop session.
- Debug build and signed Release archive/export/DMG packaging passed. Delivered build: **1.1.0 (zQHz47H)**, updated in `apps/Release` and `/Applications`. The previous running app and Applications copy were saved locally under `/private/tmp` before replacement.
- Clean restart: exactly one 1.1.0 instance remained running. Startup diagnostics reported the session keyboard tap enabled, G32 display 2 → registry 4295530218, and HP display 3 → registry 4295530184. These match the captured physical framebuffer identities.
- Connected hardware: corrected read-only probe returned G32=100%, HP=57%. Setting G32 to 70% was accepted and read back as 70%, while HP remained 57%. The original G32 hardware value was then restored. This verifies physical command/readback isolation; it does not measure panel luminance.

For a manual check after cable reconnect or real sleep/wake, lower G32 below 100% using its slider and the primary shortcut while watching HP, then repeat for HP. Cross 100% on G32 to verify HDR transitions. Do not infer hardware isolation from HUD percentages alone. Real sleep/wake and cable reconnect require a separate physical check.
