PLIST_NAME = com.flowspeak.agent
PLIST_DIR = $(HOME)/Library/LaunchAgents
PLIST_PATH = $(PLIST_DIR)/$(PLIST_NAME).plist
CONFIG_DIR = $(HOME)/.config/flowspeak
PROJECT_DIR = $(shell pwd)
APP_DIR = $(PROJECT_DIR)/dist/FlowSpeak.app
APP_CONTENTS = $(APP_DIR)/Contents
APP_EXECUTABLE = $(APP_DIR)/Contents/MacOS/FlowSpeak
APP_PLIST = $(APP_CONTENTS)/Info.plist
APP_RESOURCES = $(APP_CONTENTS)/Resources
APP_ICONSET = $(PROJECT_DIR)/build/FlowSpeak.iconset
APP_ICON = $(APP_RESOURCES)/FlowSpeak.icns
INSTALL_APP_DIR = $(HOME)/Applications/FlowSpeak.app
INSTALL_APP_EXECUTABLE = $(INSTALL_APP_DIR)/Contents/MacOS/FlowSpeak
LAUNCH_DOMAIN = gui/$(shell id -u)
LAUNCH_SERVICE = $(LAUNCH_DOMAIN)/$(PLIST_NAME)
SIGNING_IDENTITY ?= -
SIGNING_FLAGS = --force --deep --sign "$(SIGNING_IDENTITY)"
PYTHON_BASE = $(shell readlink .venv/bin/python)
PYTHON_VERSION = $(shell .venv/bin/python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_HOME = $(shell dirname $$(dirname $(PYTHON_BASE)))
PYTHON_STDLIB = $(PYTHON_HOME)/lib/python$(PYTHON_VERSION)
PYTHON_DYNLOAD = $(PYTHON_STDLIB)/lib-dynload
SITE_PACKAGES = $(PROJECT_DIR)/.venv/lib/python$(PYTHON_VERSION)/site-packages
PYTHON_CONFIG = $(PYTHON_HOME)/bin/python$(PYTHON_VERSION)-config

.PHONY: run build-app install-app autostart autostart-remove stop restart status setup-dictionary download-model help

run: ## Start FlowSpeak (foreground)
	uv run flowspeak

build-app: ## Build FlowSpeak.app for proper macOS app identity/permissions
	@rm -rf build dist
	@mkdir -p $(APP_CONTENTS)/MacOS $(APP_RESOURCES) $(APP_ICONSET)
	@cp scripts/FlowSpeak-Info.plist $(APP_PLIST)
	@cp icons/mic_idle.png $(APP_ICONSET)/icon_16x16.png
	@sips -z 32 32 icons/mic_idle.png --out $(APP_ICONSET)/icon_16x16@2x.png >/dev/null
	@sips -z 32 32 icons/mic_idle.png --out $(APP_ICONSET)/icon_32x32.png >/dev/null
	@sips -z 64 64 icons/mic_idle.png --out $(APP_ICONSET)/icon_32x32@2x.png >/dev/null
	@sips -z 128 128 icons/mic_idle.png --out $(APP_ICONSET)/icon_128x128.png >/dev/null
	@sips -z 256 256 icons/mic_idle.png --out $(APP_ICONSET)/icon_128x128@2x.png >/dev/null
	@sips -z 256 256 icons/mic_idle.png --out $(APP_ICONSET)/icon_256x256.png >/dev/null
	@sips -z 512 512 icons/mic_idle.png --out $(APP_ICONSET)/icon_256x256@2x.png >/dev/null
	@sips -z 512 512 icons/mic_idle.png --out $(APP_ICONSET)/icon_512x512.png >/dev/null
	@cp $(APP_ICONSET)/icon_512x512.png $(APP_ICONSET)/icon_512x512@2x.png
	@iconutil -c icns $(APP_ICONSET) -o $(APP_ICON)
	@clang \
		$$($(PYTHON_CONFIG) --cflags --embed) \
		-DFLOWSPEAK_PROJECT_DIR=\"$(PROJECT_DIR)\" \
		-DFLOWSPEAK_PYTHON_HOME=\"$(PYTHON_HOME)\" \
		-DFLOWSPEAK_SITE_PACKAGES=\"$(SITE_PACKAGES)\" \
		-DFLOWSPEAK_STDLIB=\"$(PYTHON_STDLIB)\" \
		-DFLOWSPEAK_DYNLOAD=\"$(PYTHON_DYNLOAD)\" \
		scripts/flowspeak_launcher.c \
		-o $(APP_EXECUTABLE) \
		$$($(PYTHON_CONFIG) --ldflags --embed)
	@echo "✓ Built $(APP_DIR)"

install-app: build-app ## Install FlowSpeak.app into ~/Applications
	@mkdir -p $(HOME)/Applications
	@rm -rf $(INSTALL_APP_DIR)
	@cp -R $(APP_DIR) $(INSTALL_APP_DIR)
	@codesign $(SIGNING_FLAGS) $(INSTALL_APP_DIR) >/dev/null 2>&1 || true
	@echo "✓ Installed $(INSTALL_APP_DIR)"

show-signing: ## Show the signing identity currently configured for app builds
	@echo "SIGNING_IDENTITY=$(SIGNING_IDENTITY)"

autostart: ## Set up FlowSpeak to start on login
	@$(MAKE) install-app
	@mkdir -p $(PLIST_DIR)
	@sed "s|__APP_BUNDLE__|$(INSTALL_APP_DIR)|g; s|__PROJECT__|$(PROJECT_DIR)|g" \
		scripts/com.flowspeak.agent.plist > $(PLIST_PATH)
	@mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/dictionary.toml || cp scripts/dictionary.example.toml $(CONFIG_DIR)/dictionary.toml
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@launchctl bootstrap $(LAUNCH_DOMAIN) $(PLIST_PATH)
	@launchctl kickstart -k $(LAUNCH_SERVICE) >/dev/null
	@echo "✓ FlowSpeak will start on login and is running now."
	@echo "  Stop:    make stop"
	@echo "  Remove:  make autostart-remove"

autostart-remove: stop ## Remove auto-start on login
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@rm -f $(PLIST_PATH)
	@echo "✓ Auto-start removed."

stop: ## Stop FlowSpeak
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@pkill -x "FlowSpeak" 2>/dev/null || true
	@echo "✓ FlowSpeak stopped."

restart: stop ## Restart FlowSpeak
	@if [ -f $(PLIST_PATH) ]; then \
		launchctl bootstrap $(LAUNCH_DOMAIN) $(PLIST_PATH); \
		launchctl kickstart -k $(LAUNCH_SERVICE) >/dev/null; \
	else \
		echo "✗ No LaunchAgent installed. Run 'make autostart' first."; \
		exit 1; \
	fi
	@echo "✓ FlowSpeak restarted."

status: ## Check if FlowSpeak is running
	@if pgrep -x "FlowSpeak" > /dev/null; then \
		echo "✓ Running (PID: $$(pgrep -x 'FlowSpeak'))"; \
	else \
		echo "✗ Not running."; \
	fi
	@if [ -f $(PLIST_PATH) ]; then \
		launchctl print $(LAUNCH_SERVICE) >/dev/null 2>&1 && echo "✓ LaunchAgent loaded." || echo "✗ LaunchAgent not loaded."; \
	else \
		echo "✗ LaunchAgent not installed."; \
	fi

setup-dictionary: ## Open dictionary for editing
	@mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/dictionary.toml || cp scripts/dictionary.example.toml $(CONFIG_DIR)/dictionary.toml
	@open -t $(CONFIG_DIR)/dictionary.toml

download-model: ## Pre-download Whisper model (~1.5GB)
	uv run python -c "import mlx_whisper, numpy as np; mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo='mlx-community/whisper-large-v3-turbo')"
	@echo "✓ Model cached."

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
