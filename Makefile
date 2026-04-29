GITHUB_USER  = moshebe
BIN_DIR      = $(HOME)/.transcribeer/bin
ENTITLEMENTS = capture/capture.entitlements.plist

PLIST_LABEL  = com.transcribeer.dev
PLIST_PATH   = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
LOG_DIR      = $(HOME)/.transcribeer/log
PROJECT_DIR  = $(CURDIR)

APP_BUNDLE   = $(PROJECT_DIR)/gui/.build/Transcribeer.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS    = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources

# Side-by-side dev variant: distinct bundle id so it can run alongside a
# normally-installed Transcribeer without conflicting over the menu bar slot
# or the launch-agent socket. MenuBarIcon shows a small orange "D" badge at
# runtime when it detects this suffix.
DEV_VARIANT_BUNDLE   = $(PROJECT_DIR)/gui/.build/Transcribeer-dev.app
DEV_VARIANT_BUNDLE_ID = com.transcribeer.menubar.dev
DEV_VARIANT_NAME     = Transcribeer (dev)

# Override with: make obsidian-plugin OBSIDIAN_VAULT=/path/to/your/vault
OBSIDIAN_VAULT ?= $(HOME)/Library/Mobile Documents/com~apple~CloudDocs/$(shell id -un)
OBSIDIAN_PLUGIN_DIR = $(OBSIDIAN_VAULT)/.obsidian/plugins/transcribeer

.PHONY: gui gui-build build-dev build-dev-variant gui-dev-variant capture test-capture logs help dev dev-uninstall dev-restart obsidian-plugin lint lint-fix lint-strict clean e2e e2e-hebrew

help:
	@echo "dev targets:"
	@echo "  make dev            install locally + register as launch agent"
	@echo "  make dev-uninstall  unload agent + remove plist"
	@echo "  make dev-restart    restart the launch agent"
	@echo "  make build-dev          build Swift GUI as .app bundle"
	@echo "  make gui                build + launch .app bundle"
	@echo "  make gui-build          build Swift binary only (no bundle)"
	@echo "  make build-dev-variant  build a side-by-side 'dev' bundle that runs alongside a main install"
	@echo "  make gui-dev-variant    build-dev-variant + launch"
	@echo "  make capture        rebuild capture-bin → ~/.transcribeer/bin"
	@echo "  make test-capture   test capture-bin directly (5s recording)"
	@echo "  make logs           stream transcribeer process logs"
	@echo "  make obsidian-plugin  build + install Obsidian plugin into vault"
	@echo "  make lint           run swiftlint (requires: brew install swiftlint)"
	@echo "  make lint-fix       auto-fix swiftlint-correctable violations"
	@echo "  make lint-strict    run swiftlint with --strict (warnings fail)"
	@echo "  make e2e-hebrew     run the Hebrew loopback e2e test (needs capture-bin + ANTHROPIC_API_KEY)"

# ── lint ──────────────────────────────────────────────────────────────────────
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --config $(PROJECT_DIR)/.swiftlint.yml

lint-fix:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --fix --config $(PROJECT_DIR)/.swiftlint.yml

lint-strict:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --config $(PROJECT_DIR)/.swiftlint.yml

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf gui/.build capture/.build
	@echo "✓ build caches cleared"

# ── dev install + launch agent ────────────────────────────────────────────────
define PLIST_CONTENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(PLIST_LABEL)</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(APP_MACOS)/TranscribeerApp</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(PROJECT_DIR)</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(LOG_DIR)/transcribeer.log</string>
  <key>StandardErrorPath</key>
  <string>$(LOG_DIR)/transcribeer.log</string>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
    <string>Background</string>
    <string>LoginWindow</string>
    <string>StandardIO</string>
    <string>System</string>
  </array>
</dict>
</plist>
endef
export PLIST_CONTENT

dev: build-dev
	@mkdir -p $(LOG_DIR)
	@if launchctl list $(PLIST_LABEL) >/dev/null 2>&1; then \
		launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL); \
		echo "✓ transcribeer restarted (TCC preserved)"; \
	else \
		echo "$$PLIST_CONTENT" > $(PLIST_PATH); \
		launchctl bootstrap gui/$$(id -u) $(PLIST_PATH); \
		echo "✓ transcribeer dev agent installed and running"; \
	fi
	@echo "  logs: $(LOG_DIR)/transcribeer.log"

dev-uninstall:
	@launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true
	@rm -f $(PLIST_PATH)
	@echo "✓ transcribeer dev agent removed"

dev-restart:
	@launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL)
	@echo "✓ transcribeer dev agent restarted"

# ── Swift native GUI ──────────────────────────────────────────────────────────
gui-build:
	cd gui && swift build -c release -q
	@echo "✓ gui binary: gui/.build/release/TranscribeerApp"

build-dev: gui-build
	@mkdir -p $(APP_MACOS) $(APP_RESOURCES)
	@cmp -s gui/.build/release/TranscribeerApp $(APP_MACOS)/TranscribeerApp || \
		cp gui/.build/release/TranscribeerApp $(APP_MACOS)/TranscribeerApp
	@cmp -s $(BIN_DIR)/capture-bin $(APP_MACOS)/capture-bin 2>/dev/null || \
		cp $(BIN_DIR)/capture-bin $(APP_MACOS)/capture-bin 2>/dev/null || true
	@cmp -s gui/Info.plist $(APP_CONTENTS)/Info.plist || \
		cp gui/Info.plist $(APP_CONTENTS)/Info.plist
	@if [ -f assets/logo.png ]; then \
		iconset_root="$$(mktemp -d /tmp/transcribeer-iconset.XXXXXX)"; \
		iconset_dir="$$iconset_root/AppIcon.iconset"; \
		mkdir -p "$$iconset_dir"; \
		sips -z 16 16 assets/logo.png --out "$$iconset_dir/icon_16x16.png" >/dev/null; \
		sips -z 32 32 assets/logo.png --out "$$iconset_dir/icon_16x16@2x.png" >/dev/null; \
		sips -z 32 32 assets/logo.png --out "$$iconset_dir/icon_32x32.png" >/dev/null; \
		sips -z 64 64 assets/logo.png --out "$$iconset_dir/icon_32x32@2x.png" >/dev/null; \
		sips -z 128 128 assets/logo.png --out "$$iconset_dir/icon_128x128.png" >/dev/null; \
		sips -z 256 256 assets/logo.png --out "$$iconset_dir/icon_128x128@2x.png" >/dev/null; \
		sips -z 256 256 assets/logo.png --out "$$iconset_dir/icon_256x256.png" >/dev/null; \
		sips -z 512 512 assets/logo.png --out "$$iconset_dir/icon_256x256@2x.png" >/dev/null; \
		sips -z 512 512 assets/logo.png --out "$$iconset_dir/icon_512x512.png" >/dev/null; \
		sips -z 1024 1024 assets/logo.png --out "$$iconset_dir/icon_512x512@2x.png" >/dev/null; \
		rm -f $(APP_RESOURCES)/AppIcon.icns; \
		iconutil --convert icns --output $(APP_RESOURCES)/AppIcon.icns "$$iconset_dir"; \
		rm -rf "$$iconset_root"; \
	fi
	@touch $(APP_BUNDLE)
	@echo "✓ app bundle: $(APP_BUNDLE)"

gui: build-dev
	open $(APP_BUNDLE)

# ── side-by-side dev variant ──────────────────────────────────────────────────
# Rebuilds the main bundle first (so binary + capture-bin + icon are fresh),
# then copies it to Transcribeer-dev.app and rewrites the Info.plist to use a
# distinct bundle id and display name. Ad-hoc re-signed because any Info.plist
# change invalidates the bundle's existing signature.
#
# The resulting bundle can run at the same time as a normally-installed
# Transcribeer: the two have different bundle ids, so macOS treats them as
# separate applications in the menu bar, the Dock, and the app switcher.
# MenuBarIcon detects the .dev suffix at runtime and overlays an orange "D"
# badge so the two menu bar icons are visually distinguishable.
build-dev-variant: build-dev
	@rm -rf $(DEV_VARIANT_BUNDLE)
	@cp -R $(APP_BUNDLE) $(DEV_VARIANT_BUNDLE)
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(DEV_VARIANT_BUNDLE_ID)" \
	  $(DEV_VARIANT_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName $(DEV_VARIANT_NAME)" \
	  $(DEV_VARIANT_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $(DEV_VARIANT_NAME)" \
	  $(DEV_VARIANT_BUNDLE)/Contents/Info.plist 2>/dev/null || \
	 /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(DEV_VARIANT_NAME)" \
	  $(DEV_VARIANT_BUNDLE)/Contents/Info.plist
	@# Drop LSUIElement so the dev variant also shows a Dock icon + Cmd+Tab entry.
	@# Main stays menubar-only (moshebe's design); dev gets a second surface so
	@# reviewers can find and use the window UI without fighting the menubar.
	@/usr/libexec/PlistBuddy -c "Delete :LSUIElement" \
	  $(DEV_VARIANT_BUNDLE)/Contents/Info.plist 2>/dev/null || true
	@codesign --force --deep --sign - $(DEV_VARIANT_BUNDLE) >/dev/null 2>&1
	@echo "✓ dev variant: $(DEV_VARIANT_BUNDLE)"
	@echo "  bundle id: $(DEV_VARIANT_BUNDLE_ID) — runs alongside a main install"

gui-dev-variant: build-dev-variant
	open -n $(DEV_VARIANT_BUNDLE)

# ── capture-bin ───────────────────────────────────────────────────────────────
capture:
	mkdir -p $(BIN_DIR)
	cd capture && swift build -c release -q
	cp capture/.build/release/capture $(BIN_DIR)/capture-bin
	chmod +x $(BIN_DIR)/capture-bin
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_DIR)/capture-bin 2>/dev/null || true
	codesign --force --sign - $(BIN_DIR)/capture-bin 2>/dev/null

# ── test capture directly (terminal has TCC) ─────────────────────────────────
test-capture:
	@mkdir -p /tmp/transcribeer-test
	@echo "Recording 5s to /tmp/transcribeer-test/test.wav — press Ctrl+C to stop early"
	$(BIN_DIR)/capture-bin /tmp/transcribeer-test/test.wav 5
	@ls -lh /tmp/transcribeer-test/test.wav

# ── e2e: Hebrew audio-loopback test ──────────────────────────────────────────
# Records system audio while playing the ivrit.ai Hebrew sample, transcribes
# with the default WhisperKit model, then asks Claude to compare the result
# to the reference transcript. Requires:
#   - capture-bin installed (make capture) + Screen Recording TCC granted
#   - $$ANTHROPIC_API_KEY in the environment
# Extra env passthrough: LANGUAGE, MODEL, SAMPLE_WAV, CAPTURE_BIN, ARTIFACTS_DIR
e2e-hebrew:
	@test -x $(BIN_DIR)/capture-bin || { echo "capture-bin missing — run: make capture"; exit 1; }
	@test -n "$$ANTHROPIC_API_KEY" || { echo "ANTHROPIC_API_KEY not set"; exit 1; }
	bash $(PROJECT_DIR)/tests/e2e/hebrew-loopback.sh

e2e: e2e-hebrew

# ── logs ──────────────────────────────────────────────────────────────────────
logs:
	log stream --predicate 'process == "TranscribeerApp" OR process == "capture-bin"' --level debug

# ── Obsidian plugin ───────────────────────────────────────────────────────────
obsidian-plugin:
	cd obsidian-plugin && npm install --silent && npm run build
	mkdir -p "$(OBSIDIAN_PLUGIN_DIR)"
	cp obsidian-plugin/main.js "$(OBSIDIAN_PLUGIN_DIR)/"
	cp obsidian-plugin/manifest.json "$(OBSIDIAN_PLUGIN_DIR)/"
	@echo "✓ Obsidian plugin installed → $(OBSIDIAN_PLUGIN_DIR)"
	@echo "  Reload Obsidian and enable the plugin in Settings → Community plugins"

.PHONY: release
release: ## Tag a release and update the Homebrew formula SHA
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.1.0"; exit 1; fi
	git tag -a v$(VERSION) -m "Release v$(VERSION)"
	git archive --format=tar.gz --prefix=transcribeer-$(VERSION)/ v$(VERSION) | \
	  shasum -a 256 | awk '{print $$1}' > /tmp/release-sha256.txt
	@echo "SHA256: $$(cat /tmp/release-sha256.txt)"
	@echo "Update Formula/transcribeer.rb:"
	@echo "  url: https://github.com/$(GITHUB_USER)/transcribeer/archive/refs/tags/v$(VERSION).tar.gz"
	@echo "  sha256: $$(cat /tmp/release-sha256.txt)"
