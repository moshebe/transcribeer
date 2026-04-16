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

# Override with: make obsidian-plugin OBSIDIAN_VAULT=/path/to/your/vault
OBSIDIAN_VAULT ?= $(HOME)/Library/Mobile Documents/com~apple~CloudDocs/$(shell id -un)
OBSIDIAN_PLUGIN_DIR = $(OBSIDIAN_VAULT)/.obsidian/plugins/transcribeer

.PHONY: gui gui-build build-dev capture test-capture logs help dev dev-uninstall dev-restart obsidian-plugin

help:
	@echo "dev targets:"
	@echo "  make dev            install locally + register as launch agent"
	@echo "  make dev-uninstall  unload agent + remove plist"
	@echo "  make dev-restart    restart the launch agent"
	@echo "  make build-dev      build Swift GUI as .app bundle"
	@echo "  make gui            build + launch .app bundle"
	@echo "  make gui-build      build Swift binary only (no bundle)"
	@echo "  make capture        rebuild capture-bin → ~/.transcribeer/bin"
	@echo "  make test-capture   test capture-bin directly (5s recording)"
	@echo "  make logs           stream transcribeer process logs"
	@echo "  make obsidian-plugin  build + install Obsidian plugin into vault"

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

dev: capture build-dev
	@mkdir -p $(LOG_DIR)
	@launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true
	@echo "$$PLIST_CONTENT" > $(PLIST_PATH)
	launchctl bootstrap gui/$$(id -u) $(PLIST_PATH)
	@echo "✓ transcribeer dev agent installed and running"
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
	cp gui/.build/release/TranscribeerApp $(APP_MACOS)/TranscribeerApp
	cp gui/Info.plist $(APP_CONTENTS)/Info.plist
	@if [ -f assets/logo.png ]; then \
		sips -s format icns assets/logo.png --out $(APP_RESOURCES)/AppIcon.icns 2>/dev/null || true; \
	fi
	@echo "✓ app bundle: $(APP_BUNDLE)"

gui: build-dev
	open $(APP_BUNDLE)

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
