GITHUB_USER  = moshebe
BIN_DIR      = $(HOME)/.transcribeer/bin
ENTITLEMENTS     = capture/capture.entitlements.plist
APP_ENTITLEMENTS = gui/Transcribeer.entitlements.plist
# Code signing identity. Defaults to a local self-signed cert "Transcribeer Dev"
# so TCC permissions (mic, screen recording) persist across rebuilds.
# Create once via Keychain Access → Certificate Assistant → Create a Certificate
# (Name: "Transcribeer Dev", Identity Type: Self Signed Root, Type: Code Signing).
# Override to "-" for ad-hoc, or to a Developer ID for release builds.
CODESIGN_IDENTITY ?= Transcribeer Dev
# Resolve to ad-hoc if the configured identity is missing from the keychain, so
# `make dev` still works on fresh clones. All codesign calls use this resolved
# value; the unresolved CODESIGN_IDENTITY is only used for the warning message.
EFFECTIVE_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(CODESIGN_IDENTITY)"' && printf '%s' '$(CODESIGN_IDENTITY)' || printf '%s' '-')

PLIST_LABEL  = com.transcribeer.dev
PLIST_PATH   = $(HOME)/Library/LaunchAgents/$(PLIST_LABEL).plist
LOG_DIR      = $(HOME)/.transcribeer/log
PROJECT_DIR  = $(CURDIR)

APP_BUNDLE   = $(PROJECT_DIR)/gui/.build/Transcribeer.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS    = $(APP_CONTENTS)/MacOS
APP_RESOURCES = $(APP_CONTENTS)/Resources

OBSIDIAN_VAULT = $(HOME)/Library/Mobile Documents/com~apple~CloudDocs/kostyay
OBSIDIAN_PLUGIN_DIR = $(OBSIDIAN_VAULT)/.obsidian/plugins/transcribeer

.PHONY: gui gui-build build-dev capture test-capture logs help dev dev-uninstall dev-restart obsidian-plugin lint lint-fix lint-strict e2e e2e-hebrew reset-mac-permissions sign check-identity setup-dev-cert

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
	@echo "  make reset-mac-permissions  kill processes + reset mic/screen TCC entries"
	@echo "  make sign           resign app bundle + capture-bin with CODESIGN_IDENTITY"
	@echo "  make check-identity validate CODESIGN_IDENTITY exists in keychain"
	@echo "  make setup-dev-cert create local self-signed code signing cert (idempotent)"
	@echo "  make logs           stream transcribeer process logs"
	@echo "  make obsidian-plugin  build + install Obsidian plugin into vault"
	@echo "  make lint           run swiftlint (requires: brew install swiftlint)"
	@echo "  make lint-fix       auto-fix swiftlint-correctable violations"
	@echo "  make lint-strict    run swiftlint with --strict (warnings fail)"
	@echo "  make e2e-hebrew     run the Hebrew loopback e2e test (needs capture-bin + ANTHROPIC_API_KEY)"

# ── lint ───────────────────────────────────────────────────────────────────────────────
lint:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --config $(PROJECT_DIR)/.swiftlint.yml

lint-fix:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --fix --config $(PROJECT_DIR)/.swiftlint.yml

lint-strict:
	@command -v swiftlint >/dev/null || { echo "swiftlint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --config $(PROJECT_DIR)/.swiftlint.yml

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

# ── codesign helpers ────────────────────────────────────────────────────────────────────
# setup-dev-cert: create the "Transcribeer Dev" self-signed code signing cert
# in the login keychain and trust it for code signing. Idempotent.
setup-dev-cert:
	@set -e; \
	if [ "$(CODESIGN_IDENTITY)" = "-" ]; then \
	  echo "→ CODESIGN_IDENTITY=- (ad-hoc); skipping cert setup"; exit 0; \
	fi; \
	case "$(CODESIGN_IDENTITY)" in \
	  Apple*|"Developer ID"*|"Mac Developer"*) \
	    echo "→ CODESIGN_IDENTITY='$(CODESIGN_IDENTITY)' is an Apple-issued identity; skipping self-signed cert setup"; exit 0;; \
	esac; \
	if security find-identity -v -p codesigning | grep -q '"$(CODESIGN_IDENTITY)"'; then \
	  echo "✓ $(CODESIGN_IDENTITY) already installed"; \
	  exit 0; \
	fi; \
	echo "→ creating self-signed code signing cert '$(CODESIGN_IDENTITY)'"; \
	WORK=$$(mktemp -d); \
	trap "rm -rf $$WORK" EXIT; \
	printf '%s\n' \
	  '[ req ]' \
	  'distinguished_name = req_dn' \
	  'x509_extensions    = v3_ca' \
	  'prompt             = no' \
	  '' \
	  '[ req_dn ]' \
	  'CN = $(CODESIGN_IDENTITY)' \
	  '' \
	  '[ v3_ca ]' \
	  'basicConstraints     = critical, CA:FALSE' \
	  'keyUsage             = critical, digitalSignature' \
	  'extendedKeyUsage     = critical, codeSigning' \
	  'subjectKeyIdentifier = hash' > $$WORK/cert.cnf; \
	openssl req -x509 -newkey rsa:2048 -nodes \
	  -keyout $$WORK/key.pem -out $$WORK/cert.pem \
	  -days 3650 -config $$WORK/cert.cnf 2>/dev/null; \
	openssl pkcs12 -export -legacy \
	  -out $$WORK/cert.p12 -inkey $$WORK/key.pem -in $$WORK/cert.pem \
	  -name "$(CODESIGN_IDENTITY)" -passout pass:tmp; \
	security import $$WORK/cert.p12 -k $$HOME/Library/Keychains/login.keychain-db \
	  -P tmp -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productsign; \
	security add-trusted-cert -p codeSign -k $$HOME/Library/Keychains/login.keychain-db $$WORK/cert.pem; \
	echo "✓ cert installed:"; \
	security find-identity -v -p codesigning | grep "$(CODESIGN_IDENTITY)" | sed 's/^/    /'


# check-identity: verify $(CODESIGN_IDENTITY) is usable. Ad-hoc ("-") always
# ok; named identity must exist in the login keychain.
check-identity:
	@if [ "$(EFFECTIVE_IDENTITY)" = "-" ] && [ "$(CODESIGN_IDENTITY)" != "-" ]; then \
		echo "⚠  codesign identity '$(CODESIGN_IDENTITY)' not found in keychain — falling back to ad-hoc."; \
		echo "   macOS will re-prompt for mic/screen permissions after every rebuild."; \
		echo "   To fix: Keychain Access → Certificate Assistant → Create a Certificate"; \
		echo "           Name: $(CODESIGN_IDENTITY)  Identity Type: Self Signed Root  Type: Code Signing"; \
	elif [ "$(EFFECTIVE_IDENTITY)" = "-" ]; then \
		echo "⚠  using ad-hoc signing — macOS will re-prompt for permissions after every rebuild."; \
	else \
		echo "✓ codesign identity: $(EFFECTIVE_IDENTITY)"; \
	fi

# sign: (re)sign existing app bundle + capture-bin with $(CODESIGN_IDENTITY)
# without rebuilding. Useful after changing CODESIGN_IDENTITY or when a prior
# build used ad-hoc.
sign: check-identity
	@if [ -f $(BIN_DIR)/capture-bin ]; then \
		echo "→ signing capture-bin"; \
		codesign --force --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(ENTITLEMENTS) --options runtime $(BIN_DIR)/capture-bin; \
	else \
		echo "→ skip capture-bin (not built)"; \
	fi
	@if [ -d $(APP_BUNDLE) ]; then \
		echo "→ signing $(APP_BUNDLE)"; \
		codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) --options runtime $(APP_BUNDLE) 2>/dev/null || \
		  codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) $(APP_BUNDLE); \
	else \
		echo "→ skip app bundle (not built)"; \
	fi
	@echo "✓ signed. Current state:"
	@[ -f $(BIN_DIR)/capture-bin ] && codesign -dv $(BIN_DIR)/capture-bin 2>&1 | grep -E 'Authority|Signature|Identifier' | sed 's/^/    capture-bin: /' || true
	@[ -d $(APP_BUNDLE) ] && codesign -dv $(APP_BUNDLE) 2>&1 | grep -E 'Authority|Signature|Identifier' | sed 's/^/    app-bundle:  /' || true

dev: setup-dev-cert capture build-dev
	@mkdir -p $(LOG_DIR)
	@launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true
	@# Wait for the previous instance to fully tear down; bootstrap errors with
	@# EIO (5) if the service is still in the process of stopping.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if ! launchctl print gui/$$(id -u)/$(PLIST_LABEL) >/dev/null 2>&1; then break; fi; \
		sleep 0.5; \
	done
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
	codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) --options runtime $(APP_BUNDLE) 2>/dev/null || \
	  codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) $(APP_BUNDLE)
	@touch $(APP_BUNDLE)
	@echo "✓ app bundle: $(APP_BUNDLE) (signed: $(EFFECTIVE_IDENTITY))"

gui: build-dev
	open $(APP_BUNDLE)

# ── capture-bin ───────────────────────────────────────────────────────────────
capture:
	mkdir -p $(BIN_DIR)
	cd capture && swift build -c release -q
	cp capture/.build/release/capture $(BIN_DIR)/capture-bin
	chmod +x $(BIN_DIR)/capture-bin
	codesign --force --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(ENTITLEMENTS) --options runtime $(BIN_DIR)/capture-bin

# ── reset macOS TCC permissions ──────────────────────────────────────────────
# Use when macOS is confused about mic/screen-recording grants after ad-hoc
# signature changes. Kills running instances, clears TCC entries for the app
# bundle ID and the standalone capture-bin, then you can relaunch to re-prompt.
reset-mac-permissions:
	@echo "→ killing running instances"
	-pkill -f TranscribeerApp 2>/dev/null || true
	-pkill -f capture-bin 2>/dev/null || true
	@echo "→ resetting user-level TCC (Microphone, ScreenCapture, SystemPolicyAllFiles)"
	-@for svc in Microphone ScreenCapture SystemPolicyAllFiles; do \
		tccutil reset $$svc com.transcribeer.menubar 2>/dev/null || true; \
	done
	@echo "→ resetting system-level TCC (Accessibility, ListenEvent, PostEvent) — needs sudo"
	-@for svc in Accessibility ListenEvent PostEvent; do \
		sudo tccutil reset $$svc com.transcribeer.menubar 2>/dev/null || true; \
	done
	@echo "→ resetting TCC for standalone capture-bin (no bundle ID → resets all)"
	-tccutil reset Microphone 2>/dev/null || true
	-tccutil reset ScreenCapture 2>/dev/null || true
	@echo "✓ done. Relaunch with: make gui"

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
	cd obsidian-plugin && npm run build
	mkdir -p "$(OBSIDIAN_PLUGIN_DIR)"
	cp obsidian-plugin/main.js "$(OBSIDIAN_PLUGIN_DIR)/"
	cp obsidian-plugin/manifest.json "$(OBSIDIAN_PLUGIN_DIR)/"
	@echo "✓ Obsidian plugin installed — reload Obsidian to pick up changes"

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
