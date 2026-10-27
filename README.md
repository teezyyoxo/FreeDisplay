# FreeDisplay

> **Free & open-source alternative to [BetterDisplay](https://github.com/waydabber/BetterDisplay)** — all the core display management features, zero cost.

BetterDisplay is a great app, but its best features are locked behind a paid Pro license. FreeDisplay implements the most essential BetterDisplay features as a completely free, open-source macOS menu bar app.

[Download Latest Release](https://github.com/teezyyoxo/FreeDisplay/releases/latest) | [Report an Issue](https://github.com/teezyyoxo/FreeDisplay/issues)

> **Credit:** FreeDisplay was created by [**huberdf**](https://github.com/huberdf) — see the [original repository](https://github.com/huberdf/FreeDisplay). This is a fork maintained by [teezyyoxo](https://github.com/teezyyoxo) that builds on that work: it adds a redesigned Liquid Glass interface, configurable brightness shortcuts, a Settings window, and a number of fixes. All credit for the original app, its architecture and its DDC/HiDPI groundwork goes to huberdf.

---

## What BetterDisplay Features Does This Replace?

| BetterDisplay Feature | FreeDisplay | Notes |
|----------------------|:-----------:|-------|
| DDC Brightness & Contrast | ✅ | Hardware control via IOKit I2C (Intel) / IOAVService (Apple Silicon) |
| Software Brightness (Gamma) | ✅ | Per-display gamma table control with smooth transitions |
| Keyboard Brightness Keys for External Displays | ✅ | Brightness keys adjust the display under the mouse pointer (works with media keys and keyboards that send F14/F15), with the native macOS OSD |
| Custom Brightness Shortcuts | ✅ | Configurable shortcuts for the primary display, the secondary display, both displays, and "match secondary to primary" |
| Liquid Glass Interface | ✅ | Glass cards on macOS 26 and later (blur material on earlier versions), with System / Light / Dark appearance |
| Auto Brightness Sync | ✅ | Syncs external display brightness with built-in display changes |
| HiDPI Virtual Displays | ✅ | Creates HiDPI dummy displays via CGVirtualDisplay private API |
| Display Arrangement | ✅ | Position displays (external above built-in, etc.) |
| Resolution & HiDPI Switching | ✅ | Browse and switch all available display modes including HiDPI |
| ICC Color Profile Management | ✅ | Switch color profiles per display via ColorSync |
| Image Adjustment (Gamma/Temperature) | ✅ | Software contrast, color temperature, RGB channels, invert |
| Display Presets | ✅ | Save & restore full display configurations with one click |
| Virtual Display (Dummy) | ✅ | Create headless virtual displays |
| Notch Management | ✅ | Hide the MacBook notch with a black overlay |
| Launch at Login | ✅ | Via SMAppService |

### Not Included (intentionally)

- Screen streaming / PiP — rarely used, adds complexity
- EDID override — requires SIP disabled
- XDR/HDR extra brightness — requires specific hardware

---

## Screenshots

*Coming soon*

---

## Installation

### Option 1: Download DMG

1. Download `FreeDisplay.dmg` from [Releases](https://github.com/teezyyoxo/FreeDisplay/releases/latest)
2. Open the DMG and drag **FreeDisplay.app** to **Applications**
3. First launch: right-click → **Open** (unsigned app, one-time approval)

### Option 2: Build from Source

```bash
brew install xcodegen
git clone https://github.com/teezyyoxo/FreeDisplay.git
cd FreeDisplay
xcodegen generate
xcodebuild -scheme FreeDisplay -configuration Release build
```

---

## Permissions

| Permission | Why |
|------------|-----|
| **Accessibility** | Required for brightness key and shortcut interception |
| **Input Monitoring** | Required to see key presses system-wide |

Grant both to FreeDisplay itself. **Settings → Brightness Keys** shows whether each is granted.

No internet connection required (except optional update checks via GitHub Releases API).

---

## Tech Stack

- **Swift 6** + **SwiftUI** (MenuBarExtra)
- **IOKit** — DDC/CI I2C for hardware brightness/contrast
- **CoreGraphics** — Display enumeration, resolution, arrangement
- **ColorSync** — ICC color profile management
- **CGVirtualDisplay** — Virtual display creation (private API, macOS 14+)
- **CoreDisplay** — Built-in display brightness reading (private API, via dlopen)
- Zero third-party dependencies

---

## Project Structure

```
FreeDisplay/
├── App/              # AppDelegate, app entry point
├── Models/           # DisplayInfo, DisplayMode, DisplayPreset, ShortcutBinding
├── Services/         # System-level services (DDC, brightness, resolution, gamma, etc.)
└── Views/            # SwiftUI views: menu panel, Settings window, shared glass design system
```

---

## How It Works

FreeDisplay sits in your menu bar and talks directly to your displays:

- **External monitors**: Uses DDC/CI protocol over I2C (Intel) or IOAVService (Apple Silicon) to control hardware brightness, contrast, and other settings
- **Built-in display**: Uses CoreGraphics gamma tables for software brightness adjustment
- **Brightness keys**: Installs a CGEventTap to intercept keyboard brightness keys and route them to the display under your mouse cursor
- **Auto brightness**: Polls the built-in display brightness via CoreDisplay private API and proportionally adjusts external displays
- **HiDPI**: Creates virtual displays via CGVirtualDisplay private API, or writes display override plists for persistent HiDPI

---

## Contributing

Issues and PRs welcome. This project uses:
- `xcodegen` for project generation (edit `project.yml`, not `.xcodeproj`)
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal`
- MVVM architecture (View → ViewModel → Service)

---

## License

The original project's README declares the MIT License, and this fork keeps it. The original repository does not currently include a `LICENSE` file, so see [huberdf/FreeDisplay](https://github.com/huberdf/FreeDisplay) for the author's terms. Original work © huberdf.

---

## Acknowledgments

- **[huberdf](https://github.com/huberdf)** — creator of [FreeDisplay](https://github.com/huberdf/FreeDisplay), the project this fork is built on
- Inspired by [BetterDisplay](https://github.com/waydabber/BetterDisplay), [MonitorControl](https://github.com/MonitorControl/MonitorControl), and [Lunar](https://lunar.fyi/)
- CGVirtualDisplay bridging header based on [Chromium's virtual_display_mac_util.mm](https://chromium.googlesource.com/chromium/src/+/main/ui/display/mac/test/virtual_display_mac_util.mm)
