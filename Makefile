BUILD := .build/release
APP := build/MagGlow.app
RES := $(APP)/Contents/Resources
DEST := /Applications/MagGlow.app
# Sign with your Apple Development certificate when there is one: macOS then
# recognises each new build as the same app and keeps its permissions
# (Calendar, Accessibility). Without one, fall back to ad-hoc signing.
SIGN ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $$2; exit }'),-)

.PHONY: build app zip install uninstall clean

build:
	swift build -c release

build/AppIcon.icns: scripts/make-icon.swift
	rm -rf build/AppIcon.iconset
	mkdir -p build
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

# The bundle carries everything needed to install the helper, so the
# one-line installer only has to download and unzip it.
app: build build/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(RES)
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	cp build/AppIcon.icns $(RES)/AppIcon.icns
	cp -R packaging/es.lproj $(RES)/
	mkdir -p $(RES)/en.lproj
	cp $(BUILD)/MagGlow $(APP)/Contents/MacOS/MagGlow
	cp $(BUILD)/MagGlowHelper $(RES)/MagGlowHelper
	cp packaging/com.magglow.helper.plist scripts/install-helper.sh scripts/uninstall.sh $(RES)/
	codesign --force --sign "$(SIGN)" $(RES)/MagGlowHelper
	codesign --force --sign "$(SIGN)" $(APP)

zip: app
	cd build && rm -f MagGlow.zip && ditto -c -k --keepParent MagGlow.app MagGlow.zip

install: app
	osascript -e 'tell application "MagGlow" to quit' >/dev/null 2>&1 || true
	rm -rf $(DEST)
	ditto $(APP) $(DEST)
	sudo $(DEST)/Contents/Resources/install-helper.sh $(USER)
	open $(DEST)

uninstall:
	sudo $(DEST)/Contents/Resources/uninstall.sh

clean:
	rm -rf .build build
