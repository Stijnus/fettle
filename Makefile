# Fettle — a native macOS app built with Xcode.
#
# `make` builds the Release app and refreshes build/Fettle.app. Keeping this
# standard entry point means the app builds the same way from a terminal, from
# an IDE, and from Craft Anything's build check (which recognizes `make`).

PROJECT := Fettle.xcodeproj
SCHEME := Fettle
CONFIG := Release
DERIVED := .build-release
APP := build/Fettle.app
BUILT := $(DERIVED)/Build/Products/$(CONFIG)/Fettle.app

.PHONY: all build test clean icon release art

all: build

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) -derivedDataPath $(DERIVED) \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
	@mkdir -p build
	@rm -rf "$(APP)"
	ditto "$(BUILT)" "$(APP)"
	@echo "Built $(APP)"

test: build
	"$(APP)/Contents/MacOS/Fettle" --self-test
	"$(APP)/Contents/MacOS/Fettle" --integration-test

clean:
	rm -rf "$(DERIVED)" "$(APP)" dist

# Regenerate every AppIcon size from scripts/make_icon.swift.
icon:
	swift scripts/make_icon.swift Fettle/Resources/Assets.xcassets/AppIcon.appiconset

# Signed app, DMG, zip and SHA-256 checksums in dist/. See scripts/release.sh.
release:
	./scripts/release.sh

# Re-capture the README screenshots and redraw the brand assets.
# Needs a logged-in GUI session and Pillow; your settings are restored afterwards.
art:
	./scripts/capture_screenshots.sh
