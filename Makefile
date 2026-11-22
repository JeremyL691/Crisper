# Crisper — convenience build & test targets (Sparkle-free standalone fork of Crisp).
#
# Fast dev loop:
#   make dev        compile + build standalone /Applications/Crisper.app + relaunch
#   make compile    compile ./Crisper-bin and ./crisperctl-bin only (quick build check)
#   make test       generate the Xcode project and run unit tests
#   make check      lint + tests + x86_64 typecheck + localization keys
#   make clean      remove build artifacts
#   make help       list targets (default)
#
# Override the target app with:
#   make dev CRISPER_APP=/path/to/Crisper.app

VERSION := $(shell grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

ifneq (,$(wildcard /Applications/Xcode.app))
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
unexport SDKROOT
endif

SWIFT_SOURCES := Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
                 Crisp/Views/*.swift Crisp/Utilities/*.swift
SWIFTC_FLAGS := -O -swift-version 6 -parse-as-library \
                -import-objc-header Crisp/Crisp-Bridging-Header.h \
                -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
                -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
                -Xlinker -undefined -Xlinker dynamic_lookup

.DEFAULT_GOAL := help
.PHONY: help dev compile test lint loc-check typecheck-x86 check clean

help:
	@echo "Crisper — make targets:"
	@echo "  make dev        compile + build standalone /Applications/Crisper.app + relaunch (dev.sh)"
	@echo "  make compile    compile ./Crisper-bin and ./crisperctl-bin only"
	@echo "  make test       generate the Xcode project and run unit tests"
	@echo "  make check      lint + tests + x86_64 typecheck + localization keys"
	@echo "  make clean      remove build artifacts"

dev:
	./dev.sh

compile:
	@echo "==> Compiling Crisper $(VERSION) -> ./Crisper-bin"
	swiftc $(SWIFTC_FLAGS) $(SWIFT_SOURCES) -o Crisper-bin
	@echo "==> Compiling crisperctl -> ./crisperctl-bin"
	swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
		Sources/crispctl/*.swift Crisp/Models/CrispControlModel.swift Crisp/Models/BrightnessKeySteps.swift \
		-o crisperctl-bin
	@echo "Done. ./Crisper-bin and ./crisperctl-bin built."

test:
	xcodegen generate
	xcodebuild -quiet test -project Crisp.xcodeproj -scheme Crisp \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

lint:
	@command -v swiftlint >/dev/null || { echo "SwiftLint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --quiet

loc-check:
	xcodegen generate
	mkdir -p build && cp Crisp/Resources/Localizable.xcstrings build/Localizable.xcstrings.orig
	xcodebuild -quiet -exportLocalizations -project Crisp.xcodeproj \
		-localizationPath build/loc CODE_SIGNING_ALLOWED=NO \
		SWIFT_EMIT_LOC_STRINGS=YES; status=$$?; \
		cp build/Localizable.xcstrings.orig Crisp/Resources/Localizable.xcstrings; exit $$status
	python3 scripts/check-localization-keys.py build/loc/en.xcloc \
		Crisp/Resources/Localizable.xcstrings scripts/i18n-missing-allowlist.txt

typecheck-x86:
	swiftc -typecheck -target x86_64-apple-macos14.0 -swift-version 6 \
		-parse-as-library -import-objc-header Crisp/Crisp-Bridging-Header.h \
		$(SWIFT_SOURCES)

check: lint test typecheck-x86 loc-check
	@echo "check passed: lint clean, tests green, x86_64 slice typechecks, localization keys complete"

clean:
	rm -f Crisper-bin crisperctl-bin Crisp-bin crispctl-bin Crisp.dmg Crisper.dmg
	rm -rf build
	@echo "Cleaned build artifacts."
