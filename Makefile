# Swift needs Xcode's toolchain: the Command Line Tools lack Testing/XCTest.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
SWIFT = swift

PLIST_NAME = com.sabbel.agent
PLIST_DIR = $(HOME)/Library/LaunchAgents
PLIST_PATH = $(PLIST_DIR)/$(PLIST_NAME).plist
CONFIG_DIR = $(HOME)/.config/sabbel
PROJECT_DIR = $(shell pwd)
INSTALL_APP_DIR = $(HOME)/Applications/Sabbel.app
LAUNCH_DOMAIN = gui/$(shell id -u)
LAUNCH_SERVICE = $(LAUNCH_DOMAIN)/$(PLIST_NAME)
# "dev" or a tag without its "v"; becomes SabbelVersion in Info.plist.
VERSION ?= dev

.PHONY: build test test-model test-e2e build-app install-app reset-permissions ensure-app-installed autostart autostart-remove stop restart status download-model clean eval help

test-e2e: build-app ## End-to-end check on this Mac: real app, model and paste (hands off ~30s; the terminal needs Accessibility)
	dist/Sabbel.app/Contents/MacOS/Sabbel --e2e

icons/Sabbel.icns: icons/sabbel-icon.png ## Generate app icon from sabbel-icon.png
	@mkdir -p build/Sabbel.iconset
	@cp icons/sabbel-icon.png build/Sabbel.iconset/icon_512x512@2x.png
	@sips -z 512 512 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_512x512.png >/dev/null
	@sips -z 256 256 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_256x256@2x.png >/dev/null
	@sips -z 256 256 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_256x256.png >/dev/null
	@sips -z 128 128 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_128x128@2x.png >/dev/null
	@sips -z 128 128 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_128x128.png >/dev/null
	@sips -z 64 64 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_32x32@2x.png >/dev/null
	@sips -z 32 32 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_32x32.png >/dev/null
	@sips -z 32 32 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_16x16@2x.png >/dev/null
	@sips -z 16 16 icons/sabbel-icon.png --out build/Sabbel.iconset/icon_16x16.png >/dev/null
	@iconutil -c icns build/Sabbel.iconset -o icons/Sabbel.icns

build-app: build icons/Sabbel.icns ## Build and sign dist/Sabbel.app (Swift); VERSION=1.2.3, SABBEL_SIGN_IDENTITY=...
	@scripts/bundle_app.sh $(VERSION)

# Permissions are reset only when the installed app's signature differs from
# the new one (ad hoc, or another designated requirement); see install.sh.
install-app: build-app ## Install Sabbel.app into ~/Applications (resets permissions only if the signature changed)
	@pkill -x "Sabbel" 2>/dev/null || true
	@launchctl bootout $(LAUNCH_SERVICE) 2>/dev/null || true
	@if [ -d "$(INSTALL_APP_DIR)" ]; then \
		SABBEL_INSTALL_LIB=1; export SABBEL_INSTALL_LIB; . ./install.sh; \
		if sabbel_tcc_reset_needed "$(INSTALL_APP_DIR)" dist/Sabbel.app; then \
			sabbel_reset_tcc; \
			echo "✓ Signature changed: Accessibility + Microphone permissions reset, grant them again on launch"; \
		else \
			echo "✓ Same signature: Accessibility + Microphone permissions kept"; \
		fi; \
	fi
	@mkdir -p $(HOME)/Applications
	@rm -rf $(INSTALL_APP_DIR)
	@cp -R dist/Sabbel.app $(INSTALL_APP_DIR)
	@echo "✓ Installed $(INSTALL_APP_DIR)"

reset-permissions: ## Reset Accessibility + Microphone permissions for Sabbel
	@tccutil reset Accessibility com.sabbel.app 2>/dev/null || true
	@tccutil reset Microphone com.sabbel.app 2>/dev/null || true
	@echo "✓ Permissions reset. Relaunch Sabbel to re-grant."

ensure-app-installed:
	@if [ -d "$(INSTALL_APP_DIR)" ]; then \
		echo "✓ Reusing existing $(INSTALL_APP_DIR)"; \
	else \
		$(MAKE) install-app; \
	fi

autostart: ensure-app-installed ## Set up Sabbel to start on login
	@mkdir -p $(PLIST_DIR)
	@sed "s|__APP_BUNDLE__|$(INSTALL_APP_DIR)|g; s|__PROJECT__|$(PROJECT_DIR)|g" \
		scripts/com.sabbel.agent.plist > $(PLIST_PATH)
	@mkdir -p $(CONFIG_DIR)
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@launchctl bootstrap $(LAUNCH_DOMAIN) $(PLIST_PATH)
	@launchctl kickstart -k $(LAUNCH_SERVICE) >/dev/null
	@echo "✓ Sabbel will start on login and is running now."
	@echo "  Stop:    make stop"
	@echo "  Restart: make restart"
	@echo "  Reinstall after changes: make install-app"
	@echo "  Remove:  make autostart-remove"

autostart-remove: stop ## Remove auto-start on login
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@rm -f $(PLIST_PATH)
	@echo "✓ Auto-start removed."

stop: ## Stop Sabbel
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@pkill -x "Sabbel" 2>/dev/null || true
	@echo "✓ Sabbel stopped."

restart: stop ## Restart Sabbel
	@if [ -f $(PLIST_PATH) ]; then \
		launchctl bootstrap $(LAUNCH_DOMAIN) $(PLIST_PATH); \
		launchctl kickstart -k $(LAUNCH_SERVICE) >/dev/null; \
	else \
		echo "✗ No LaunchAgent installed. Run 'make autostart' first."; \
		exit 1; \
	fi
	@echo "✓ Sabbel restarted."

status: ## Check if Sabbel is running
	@if pgrep -x "Sabbel" > /dev/null; then \
		echo "✓ Running (PID: $$(pgrep -x 'Sabbel'))"; \
	else \
		echo "✗ Not running."; \
	fi
	@if [ -f $(PLIST_PATH) ]; then \
		launchctl print $(LAUNCH_SERVICE) >/dev/null 2>&1 && echo "✓ LaunchAgent loaded." || echo "✗ LaunchAgent not loaded."; \
	else \
		echo "✗ LaunchAgent not installed."; \
	fi

download-model: ## Pre-download the Parakeet model (loads it once via a native model test)
	SABBEL_MODEL_TESTS=1 $(SWIFT) test --package-path native --filter ModelTests/englishPhrase
	@echo "✓ Model cached."

clean: ## Remove all build artifacts (forces full rebuild)
	@rm -rf build dist
	@echo "✓ Build cache cleared."

build: ## Build the native Swift package (release)
	$(SWIFT) build --package-path native -c release

test: ## Run the native Swift tests, the eval-scorer check and the installer's permission test
	python3 -I scripts/test_eval_score.py
	sh scripts/test_install_tcc.sh
	$(SWIFT) test --package-path native

test-model: ## Run the native tests against the real Parakeet model (slow, needs the model and the Anna voice)
	SABBEL_MODEL_TESTS=1 $(SWIFT) test --package-path native --filter SabbelEngineTests

# Accuracy gate over private meeting clips. Prints only the score table; every
# output stays under $$SABBEL_EVAL_DIR/runs/.
eval: ## Score full vs stream (clips and long takes) over $$SABBEL_EVAL_DIR
	@test -n "$(SABBEL_EVAL_DIR)" || { echo "SABBEL_EVAL_DIR is not set (the dir with clips/ and refs.json)"; exit 1; }
	@set -e; D="$(SABBEL_EVAL_DIR)"; D="$${D/#\~/$$HOME}"; R="$$D/runs/$$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$$R"; \
		$(SWIFT) build --package-path native -c release --product sabbel-eval >/dev/null 2>&1 || \
			{ $(SWIFT) build --package-path native -c release --product sabbel-eval 2>&1 | tail -20; exit 1; }; \
		BIN=$$($(SWIFT) build --package-path native -c release --show-bin-path)/sabbel-eval; \
		G=""; test -f "$$D/glossary.txt" && G="--glossary $$D/glossary.txt"; \
		for m in full stream; do \
			"$$BIN" --clips "$$D/clips" --out "$$R/$$m.jsonl" --mode $$m --model "$${SABBEL_EVAL_MODEL:-v3}" \
				--long 60,300 --refs "$$D/refs.json" --long-out "$$R/long" $$G >/dev/null 2>"$$R/$$m.err" || \
				{ echo "sabbel-eval $$m failed (see $$R/$$m.err)"; exit 1; }; \
		done; \
		python3 -I scripts/eval_score.py "$$D/refs.json" "$$R/full.jsonl" "$$R/stream.jsonl"; \
		for n in 60 300; do python3 -I scripts/eval_score.py "$$R/long/refs-long$$n.json" "$$R/full-long$$n.jsonl" "$$R/stream-long$$n.jsonl" | tail -n +2; done

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
