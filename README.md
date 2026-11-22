<div align="center">

<img src="docs/icon.png" width="128" alt="Crisper icon">

# Crisper

**Streamlined macOS menu bar display manager with Smart Dummy & AC-Aware Keep Awake.**

Free, open-source display management for macOS built on [Crisp](https://github.com/didriksg/Crisp).<br>
Sharp HiDPI scaling, DDC brightness & volume, Smart Dummy virtual displays, and AC-aware sleep prevention.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](#requirements)
[![License](https://img.shields.io/github/license/JeremyL691/Crisper?color=3fb950)](LICENSE)
[![CI](https://github.com/JeremyL691/Crisper/actions/workflows/ci.yml/badge.svg)](https://github.com/JeremyL691/Crisper/actions/workflows/ci.yml)

</div>

---

Crisper is a lightweight, native macOS menu bar app for managing external monitors, headless Mac setups, and clamshell workflows. Built on [Crisp](https://github.com/didriksg/Crisp), it streamlines the menu bar and adds **Smart Dummy** (`CGVirtualDisplay` with Auto-Yield, clamshell stay-awake guard, and AC-only auto-suspend/restore) alongside **AC-Aware Keep Awake** (`Always Awake` and `On AC Power` modes).

Available in English, 简体中文, and 繁體中文.

## Highlights

- **Smart Dummy (Event-Driven `CGVirtualDisplay`)**: Automatically creates a virtual HiDPI display when no physical external display is active, and **Auto-Yields** (tears down) the moment a real display connects. Includes a **clamshell stay-awake guard** and **AC-only auto-suspend/restore** so headless remote sessions stay crisp without draining battery.
- **AC-Aware Keep Awake**: Choose between **Always Awake** and **On AC Power** modes. Coordinates with Smart Dummy so remote-control power cutoffs or unplugging AC cleanly suspend both Keep Awake and the virtual display, then restore them when power returns.
- **Streamlined Menu Bar**: Focused, clutter-free menu bar panel with quick access to display controls, Smart Dummy status, and Keep Awake mode.
- **External Monitor Controls**: Sharp HiDPI scaling (including smooth scaling), real hardware brightness and speaker volume over DDC, software dimming, Extra Brightness (HDR headroom), soft-disconnect/reconnect, DDC input switching, and ICC profiles & color adjustments.
- **Automation (`crisperctl` & Shortcuts)**: CLI control via `crisperctl` (including virtual display, brightness, HDR, input switching, and display toggling) alongside native macOS Shortcuts actions.

## Smart Dummy + Keep Awake (On AC Power) State Matrix

| Power Source | Active Physical Display (External / Open Lid) | Smart Dummy | Keep Awake (`On AC Power`) |
| :--- | :--- | :--- | :--- |
| **AC Power** | None (Clamshell / Disconnected) | Active (Virtual Display) | Active (Awake) |
| **AC Power** | Present | Yielded (Auto-Yield) | Active (Awake) |
| **Battery** | None | Suspended | Suspended |
| **Battery** | Present | Yielded (Auto-Yield) | Suspended |

## Building & Installing

Requires macOS 14+, Xcode (or Command Line Tools for `make compile` / `dev.sh`), and `xcodegen` (`brew install xcodegen`).

```sh
# Build and launch /Applications/Crisper.app with swiftc (via ./dev.sh)
make dev

# Fast edit-compile-swap loop without launching
CRISPER_NO_LAUNCH=1 ./dev.sh

# Generate Xcode project (Crisp.xcodeproj)
xcodegen generate && open Crisp.xcodeproj

# Run unit tests
make test

# Run full CI checks locally (SwiftLint strict, tests, x86_64 typecheck, localization check)
make check
```

See [docs/BUILDING.md](docs/BUILDING.md) for standalone `swiftc` builds, `crisperctl`, and Shortcuts metadata details.

## Requirements

- macOS 14 (Sonoma) or later; on macOS 26 the panel uses the native Liquid Glass backdrop.

## Permissions

- **Administrator password** (one-time, per monitor): Needed only when enabling smooth scaling, which writes a display override file into `/Library/Displays/Contents/Resources/Overrides`. Regular HiDPI scaling and all other features are password-free.
- **Accessibility** (System Settings > Privacy & Security > Accessibility): Needed only if you enable Brightness Keys to route keyboard brightness keys to external displays.

## `crisperctl` Quick Examples

Crisper must be running to accept `crisperctl` commands:

```sh
crisperctl display list                  # text list of displays
crisperctl display list --json           # JSON with each display's id and uuid
crisperctl brightness set <display> 40
crisperctl display toggle <display>
crisperctl virtual list
crisperctl virtual on "Smart Dummy"
```

Run `crisperctl help` for all commands, or `--help` on any subcommand.

## Origin & License

Crisper is built on [Crisp](https://github.com/didriksg/Crisp) by Didrik Galteland, which began as a fork of [FreeDisplay](https://github.com/huberdf/FreeDisplay).

Released under the [MIT License](LICENSE). Third-party and upstream notices are preserved in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
