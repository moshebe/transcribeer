GITHUB_USER  = moshebe
BIN_DIR      = $(HOME)/.transcribeer/bin
APP_ENTITLEMENTS = gui/Transcribeer.entitlements.plist
# Code signing identity. Defaults to a local self-signed cert "Transcribeer Dev"
# so TCC permissions (microphone, system audio recording) persist across rebuilds.
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
# Stamp file touched after a successful bundle assemble+sign. Used to skip the
# whole cp/codesign/agent-restart dance when nothing actually changed.
# Lives outside the bundle so codesign --deep doesn't trip on a foreign file.
APP_STAMP    = $(PROJECT_DIR)/gui/.build/.build-dev.stamp
# Backup of the unsigned release binary as it was when last bundled. We compare
# the freshly-built release binary against this — not against the bundle binary,
# which codesign rewrites in place — to decide whether a rebuild is needed.
# Lives outside the bundle for the same reason as APP_STAMP: codesign --deep
# would otherwise treat it as a nested executable and bail with
# errSecInternalComponent.
APP_UNSIGNED_BACKUP = $(PROJECT_DIR)/gui/.build/TranscribeerApp.unsigned

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

.PHONY: gui gui-build build-dev build-dev-variant gui-dev-variant logs help dev dev-uninstall dev-restart start stop obsidian-plugin lint lint-fix lint-strict clean reset-mac-permissions sign check-identity setup-dev-cert verify-capture

help:
	@echo "dev targets:"
	@echo "  make dev            install locally + register as launch agent"
	@echo "  make dev-uninstall  unload agent + remove plist"
	@echo "  make dev-restart    restart the launch agent"
	@echo "  make start          ensure the dev agent is loaded and running (no rebuild)"
	@echo "  make stop           stop the running dev agent process (keeps plist)"
	@echo "  make build-dev          build Swift GUI as .app bundle"
	@echo "  make gui                build + launch .app bundle"
	@echo "  make gui-build          build Swift binary only (no bundle)"
	@echo "  make build-dev-variant  build a side-by-side 'dev' bundle that runs alongside a main install"
	@echo "  make gui-dev-variant    build-dev-variant + launch"
	@echo "  make reset-mac-permissions  kill processes + reset mic/system-audio TCC entries"
	@echo "  make sign           resign app bundle with CODESIGN_IDENTITY"
	@echo "  make check-identity validate CODESIGN_IDENTITY exists in keychain"
	@echo "  make setup-dev-cert create local self-signed code signing cert (idempotent)"
	@echo "  make logs           stream transcribeer process logs"
	@echo "  make obsidian-plugin  build + install Obsidian plugin into vault"
	@echo "  make lint           run swiftlint (requires: brew install swiftlint)"
	@echo "  make lint-fix       auto-fix swiftlint-correctable violations"
	@echo "  make lint-strict    run swiftlint with --strict (warnings fail)"
	@echo "  make verify-capture  manual real-audio pipeline check (needs built .app + TCC)"


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

# ── verify capture (manual E2E, needs built .app + TCC) ────────────────────
verify-capture:
	@bash $(PROJECT_DIR)/scripts/verify-capture.sh

# ── clean ─────────────────────────────────────────────────────────────────────
clean:
	rm -rf gui/.build
	rm -f $(APP_STAMP)
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

# sign: (re)sign existing app bundle with $(CODESIGN_IDENTITY) without
# rebuilding. Useful after changing CODESIGN_IDENTITY or when a prior build
# used ad-hoc.
sign: check-identity
	@if [ -d $(APP_BUNDLE) ]; then \
		echo "→ signing $(APP_BUNDLE)"; \
		codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) --options runtime $(APP_BUNDLE) 2>/dev/null || \
		  codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) $(APP_BUNDLE); \
	else \
		echo "→ skip app bundle (not built)"; \
	fi
	@echo "✓ signed. Current state:"
	@[ -d $(APP_BUNDLE) ] && codesign -dv $(APP_BUNDLE) 2>&1 | grep -E 'Authority|Signature|Identifier' | sed 's/^/    app-bundle:  /' || true

# `make dev` stops the running agent BEFORE re-codesigning the bundle so
# launchd can't try to relaunch into a half-signed binary ("Launch Constraint
# Violation" / CODESIGNING). The binary inside the bundle is then swapped via
# atomic rename in `build-dev` so even a still-running instance survives the
# replace cleanly until launchctl kickstart restarts it below.
#
# To avoid restarting (and thus dropping the menubar) on no-op runs, we record
# $(APP_STAMP)'s mtime before invoking build-dev. If the stamp didn't move,
# nothing was rebuilt and we leave the running agent alone.
dev: setup-dev-cert
	@mkdir -p $(LOG_DIR)
	@: "Reference file captures the stamp's mtime before build-dev runs."; \
	: "Using touch -r + test -nt is portable across BSD and GNU coreutils,"; \
	: "unlike stat -f %m (BSD) vs stat -c %Y (GNU) which diverge on this box."; \
	ref=$$(mktemp -t transcribeer-stamp-ref.XXXXXX); \
	trap 'rm -f $$ref' EXIT; \
	if [ -f $(APP_STAMP) ]; then touch -r $(APP_STAMP) $$ref; else : > $$ref; fi; \
	agent_running=0; \
	if launchctl list $(PLIST_LABEL) >/dev/null 2>&1; then agent_running=1; fi; \
	$(MAKE) --no-print-directory build-dev || exit $$?; \
	if [ -f $(APP_STAMP) ] && [ ! $(APP_STAMP) -nt $$ref ] && [ $$agent_running -eq 1 ]; then \
		echo "✓ no rebuild needed — leaving running agent alone"; \
		echo "  logs: $(LOG_DIR)/transcribeer.log"; \
		exit 0; \
	fi; \
	if [ $$agent_running -eq 1 ]; then \
		launchctl kill SIGTERM gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true; \
		while launchctl list $(PLIST_LABEL) 2>/dev/null | grep -q '"PID" ='; do sleep 0.1; done; \
		launchctl kickstart gui/$$(id -u)/$(PLIST_LABEL); \
		echo "✓ transcribeer restarted (TCC preserved)"; \
	else \
		echo "$$PLIST_CONTENT" > $(PLIST_PATH); \
		launchctl bootstrap gui/$$(id -u) $(PLIST_PATH); \
		echo "✓ transcribeer dev agent installed and running"; \
	fi; \
	echo "  logs: $(LOG_DIR)/transcribeer.log"

dev-uninstall:
	@launchctl bootout gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true
	@rm -f $(PLIST_PATH)
	@echo "✓ transcribeer dev agent removed"

dev-restart:
	@launchctl kickstart -k gui/$$(id -u)/$(PLIST_LABEL)
	@echo "✓ transcribeer dev agent restarted"

# start: ensure the dev agent is loaded AND its process is actually running.
# Useful when the agent is loaded but the process was killed manually — the
# plist has no KeepAlive, so launchd won't relaunch it on its own. `make dev`
# short-circuits in that state because it only checks whether the agent is
# loaded, not whether the process is alive.
start:
	@mkdir -p $(LOG_DIR)
	@if [ ! -d $(APP_BUNDLE) ]; then \
		echo "✗ app bundle missing: $(APP_BUNDLE) — run 'make dev' first"; exit 1; \
	fi
	@if ! launchctl list $(PLIST_LABEL) >/dev/null 2>&1; then \
		echo "$$PLIST_CONTENT" > $(PLIST_PATH); \
		launchctl bootstrap gui/$$(id -u) $(PLIST_PATH); \
		echo "✓ transcribeer dev agent installed and running"; \
	elif launchctl list $(PLIST_LABEL) 2>/dev/null | grep -q '"PID" ='; then \
		echo "✓ transcribeer already running"; \
	else \
		launchctl kickstart gui/$$(id -u)/$(PLIST_LABEL); \
		echo "✓ transcribeer started"; \
	fi
	@echo "  logs: $(LOG_DIR)/transcribeer.log"

stop:
	@if launchctl list $(PLIST_LABEL) 2>/dev/null | grep -q '"PID" ='; then \
		launchctl kill SIGTERM gui/$$(id -u)/$(PLIST_LABEL) 2>/dev/null || true; \
		while launchctl list $(PLIST_LABEL) 2>/dev/null | grep -q '"PID" ='; do sleep 0.1; done; \
		echo "✓ transcribeer stopped (agent still loaded; 'make start' to relaunch)"; \
	else \
		echo "✓ transcribeer not running"; \
	fi

# ── Swift native GUI ──────────────────────────────────────────────────────────
gui-build:
	cd gui && swift build -c release -q
	@echo "✓ gui binary: gui/.build/release/TranscribeerApp"

# build-dev is incremental: a no-op `swift build` paired with an unsigned
# release binary that matches APP_UNSIGNED_BACKUP byte-for-byte skips the
# whole cp + icon + codesign dance. We compare against APP_UNSIGNED_BACKUP
# rather than the in-bundle binary because codesign rewrites the latter in
# place, so the unsigned release output and the signed bundle copy would
# never match. Earlier versions kept that backup inside Contents/MacOS/,
# which triggered codesign --deep → errSecInternalComponent on the foreign
# Mach-O sibling; it now lives next to APP_STAMP, outside the bundle.
build-dev: gui-build
	@if [ -f $(APP_STAMP) ] && [ -d $(APP_BUNDLE) ] \
		&& cmp -s gui/.build/release/TranscribeerApp $(APP_UNSIGNED_BACKUP) \
		&& cmp -s gui/Info.plist $(APP_CONTENTS)/Info.plist \
		&& [ ! $(APP_ENTITLEMENTS) -nt $(APP_STAMP) ] \
		&& { [ ! -f assets/logo.png ] || [ ! assets/logo.png -nt $(APP_STAMP) ]; }; then \
		echo "✓ app bundle up to date: $(APP_BUNDLE)"; \
		exit 0; \
	fi; \
	set -e; \
	mkdir -p $(APP_MACOS) $(APP_RESOURCES); \
	rm -f $(APP_MACOS)/capture-bin $(APP_MACOS)/TranscribeerApp.unsigned; \
	: "Atomic replace: copy to a sibling then rename(2). The running app's"; \
	: "mmap keeps the old inode alive (unaffected) while the new file gets"; \
	: "a fresh inode. In-place cp would mutate the live inode's pages and"; \
	: "the kernel would kill the running process with CODESIGNING / Invalid"; \
	: "Page on the next cold code-page fault."; \
	if ! cmp -s gui/.build/release/TranscribeerApp $(APP_UNSIGNED_BACKUP) 2>/dev/null; then \
		cp gui/.build/release/TranscribeerApp $(APP_MACOS)/TranscribeerApp.new; \
		mv -f $(APP_MACOS)/TranscribeerApp.new $(APP_MACOS)/TranscribeerApp; \
		cp gui/.build/release/TranscribeerApp $(APP_UNSIGNED_BACKUP); \
	fi; \
	cmp -s gui/Info.plist $(APP_CONTENTS)/Info.plist || \
		cp gui/Info.plist $(APP_CONTENTS)/Info.plist; \
	if [ -f assets/logo.png ] && [ assets/logo.png -nt $(APP_RESOURCES)/AppIcon.icns ]; then \
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
	fi; \
	codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) --options runtime $(APP_BUNDLE) 2>/dev/null || \
	  codesign --force --deep --sign "$(EFFECTIVE_IDENTITY)" --entitlements $(APP_ENTITLEMENTS) $(APP_BUNDLE); \
	touch $(APP_STAMP); \
	echo "✓ app bundle: $(APP_BUNDLE) (signed: $(EFFECTIVE_IDENTITY))"

gui: build-dev
	open $(APP_BUNDLE)

# ── side-by-side dev variant ──────────────────────────────────────────────────
# Rebuilds the main bundle first (so binary + icon are fresh),
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

# ── reset macOS TCC permissions ──────────────────────────────────────────────
# Use when macOS is confused about mic/screen-recording grants after ad-hoc
# signature changes. Kills running instances, clears TCC entries for the app
# bundle ID, then you can relaunch to re-prompt.
reset-mac-permissions:
	@echo "→ killing running instances"
	-pkill -f TranscribeerApp 2>/dev/null || true
	@echo "→ resetting user-level TCC (Microphone, SystemAudioRecording, SystemPolicyAllFiles)"
	-@for svc in Microphone SystemAudioRecording SystemPolicyAllFiles; do \
		tccutil reset $$svc com.transcribeer.menubar 2>/dev/null || true; \
	done
	@echo "→ resetting system-level TCC (Accessibility, ListenEvent, PostEvent) — needs sudo"
	-@for svc in Accessibility ListenEvent PostEvent; do \
		sudo tccutil reset $$svc com.transcribeer.menubar 2>/dev/null || true; \
	done
	@echo "✓ done. Relaunch with: make gui"

# ── logs ──────────────────────────────────────────────────────────────────────
logs:
	log stream --predicate 'process == "TranscribeerApp"' --level debug

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
