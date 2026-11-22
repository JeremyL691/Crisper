# Building Crisper

Crisper builds without Sparkle or external binary dependencies. You can use the `Makefile` targets, `./dev.sh` for a fast Command Line Tools loop, or Xcode directly.

## Quick Commands

```sh
make dev          # Build and launch /Applications/Crisper.app (via ./dev.sh)
make compile      # Standalone arm64 swiftc smoke build (Crisper-bin + crisperctl-bin)
make test         # Run unit tests via xcodebuild
make check        # Run SwiftLint (strict), unit tests, x86_64 typecheck, and localization check
```

To build and swap the binary without launching:

```sh
CRISPER_NO_LAUNCH=1 ./dev.sh
```

## Xcode

```sh
brew install xcodegen
xcodegen generate   # Generates Crisp.xcodeproj from project.yml
open Crisp.xcodeproj
```

## Shortcuts Actions

Shortcuts discovers Crisper's actions through `Contents/Resources/Metadata.appintents`, which Xcode generates automatically. For `swiftc` builds, `scripts/appintents.sh` emits App Intents const values and runs `appintentsmetadataprocessor` (requires Xcode's toolchain). After deploying updated actions, refresh Launch Services and relaunch Shortcuts:

```sh
lsregister -f /Applications/Crisper.app
```

## `crisperctl`

To build `crisperctl` standalone with `swiftc`:

```sh
swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
  Sources/crispctl/*.swift Crisp/Models/CrispControlModel.swift Crisp/Models/BrightnessKeySteps.swift \
  -o crisperctl-bin
```

With Xcode, `xcodegen generate && xcodebuild -project Crisp.xcodeproj -scheme crispctl -configuration Release` builds the same target.

## Before Opening a PR

Run `make check` locally (requires Xcode, `swiftlint`, and `xcodegen`: `brew install swiftlint xcodegen`). To run it automatically on every push:

```sh
git config core.hooksPath .githooks
```

The app icon is generated from vector code via `scripts/generate-icon.swift`.
