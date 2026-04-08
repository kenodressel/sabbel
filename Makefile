PLIST_NAME = com.flowspeak.agent
PLIST_DIR = $(HOME)/Library/LaunchAgents
PLIST_PATH = $(PLIST_DIR)/$(PLIST_NAME).plist
CONFIG_DIR = $(HOME)/.config/flowspeak
VENV_PYTHON = $(shell pwd)/.venv/bin/python
PROJECT_DIR = $(shell pwd)

.PHONY: run autostart autostart-remove stop restart status setup-dictionary download-model help

run: ## Start FlowSpeak (foreground)
	uv run flowspeak

autostart: ## Set up FlowSpeak to start on login
	@uv sync --quiet
	@mkdir -p $(PLIST_DIR)
	@sed "s|__PYTHON__|$(VENV_PYTHON)|g; s|__PROJECT__|$(PROJECT_DIR)|g" \
		scripts/com.flowspeak.agent.plist > $(PLIST_PATH)
	@mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/dictionary.toml || cp scripts/dictionary.example.toml $(CONFIG_DIR)/dictionary.toml
	@launchctl load $(PLIST_PATH) 2>/dev/null || true
	@echo "✓ FlowSpeak will start on login and is running now."
	@echo "  Stop:    make stop"
	@echo "  Remove:  make autostart-remove"

autostart-remove: stop ## Remove auto-start on login
	@launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@rm -f $(PLIST_PATH)
	@echo "✓ Auto-start removed."

stop: ## Stop FlowSpeak
	@launchctl unload $(PLIST_PATH) 2>/dev/null || true
	@pkill -f "python.*flowspeak" 2>/dev/null || true
	@echo "✓ FlowSpeak stopped."

restart: stop ## Restart FlowSpeak
	@launchctl load $(PLIST_PATH) 2>/dev/null || true
	@echo "✓ FlowSpeak restarted."

status: ## Check if FlowSpeak is running
	@if pgrep -f "python.*flowspeak" > /dev/null; then \
		echo "✓ Running (PID: $$(pgrep -f 'python.*flowspeak'))"; \
	else \
		echo "✗ Not running."; \
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
