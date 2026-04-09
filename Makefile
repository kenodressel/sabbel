PLIST_NAME = com.sabbel.agent
PLIST_DIR = $(HOME)/Library/LaunchAgents
PLIST_PATH = $(PLIST_DIR)/$(PLIST_NAME).plist
CONFIG_DIR = $(HOME)/.config/sabbel
PROJECT_DIR = $(shell pwd)
INSTALL_APP_DIR = $(HOME)/Applications/Sabbel.app
LAUNCH_DOMAIN = gui/$(shell id -u)
LAUNCH_SERVICE = $(LAUNCH_DOMAIN)/$(PLIST_NAME)

.PHONY: run build-app install-app reinstall-app ensure-app-installed autostart autostart-remove stop restart status setup-dictionary download-model help

run: ## Start Sabbel (foreground)
	uv run sabbel

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

build-app: icons/Sabbel.icns ## Build standalone Sabbel.app with py2app
	@rm -rf build dist
	uv run --extra build python setup.py py2app
	@# mlx.metallib is a Metal shader archive (not Mach-O), so py2app's
	@# frameworks option cannot process it.  Copy it manually next to
	@# libmlx.dylib where MLX expects to find it.
	@METALLIB=$$(find .venv -name "mlx.metallib" -type f 2>/dev/null | head -1); \
		if [ -n "$$METALLIB" ]; then \
			cp "$$METALLIB" dist/Sabbel.app/Contents/Frameworks/mlx.metallib; \
			echo "✓ Copied mlx.metallib into Frameworks"; \
		fi
	@# mlx is a namespace package (no __init__.py) so py2app only bundles
	@# core.so via import analysis.  Copy the full mlx Python package and
	@# remove the incomplete stubs from the zip so the filesystem copy
	@# takes precedence at runtime.
	@MLX_PKG=$$(find .venv -type d -name "mlx" -path "*/site-packages/mlx" | head -1); \
		if [ -n "$$MLX_PKG" ]; then \
			PYVER=$$(ls dist/Sabbel.app/Contents/Resources/lib/ | grep python3 | grep -v zip | head -1); \
			DEST=dist/Sabbel.app/Contents/Resources/lib/$$PYVER/mlx; \
			mkdir -p "$$DEST"; \
			cp -R "$$MLX_PKG"/* "$$DEST"/; \
			echo "✓ Copied mlx package into bundle"; \
		fi
	@ZIPFILE=$$(find dist/Sabbel.app/Contents/Resources/lib -name "python3*.zip" | head -1); \
		if [ -n "$$ZIPFILE" ]; then \
			python3 -c "import zipfile,shutil; src='$$ZIPFILE'; tmp=src+'.tmp'; zi=zipfile.ZipFile(src,'r'); zo=zipfile.ZipFile(tmp,'w'); [zo.writestr(i,zi.read(i.filename)) for i in zi.infolist() if not i.filename.startswith('mlx/')]; zi.close(); zo.close(); shutil.move(tmp,src)"; \
			echo "✓ Removed mlx stubs from zip"; \
		fi
	@# Fix mlx/core.so rpath: py2app rewrites libmlx.dylib's install name
	@# to @executable_path/../Frameworks/libmlx.dylib, but core.so still
	@# has @rpath/libmlx.dylib with rpath=@loader_path/lib.  Add the
	@# Frameworks dir so @rpath resolution finds the bundled dylib.
	@CORE_SO=$$(find dist/Sabbel.app -name "core.so" -path "*/mlx/*" 2>/dev/null | head -1); \
		if [ -n "$$CORE_SO" ]; then \
			install_name_tool -add_rpath @executable_path/../Frameworks "$$CORE_SO" 2>/dev/null || true; \
			codesign --force --sign - "$$CORE_SO" 2>/dev/null || true; \
			echo "✓ Fixed mlx/core.so rpath"; \
		fi
	@echo "✓ Built dist/Sabbel.app"

install-app: build-app ## Install Sabbel.app into ~/Applications
	@mkdir -p $(HOME)/Applications
	@rm -rf $(INSTALL_APP_DIR)
	@cp -R dist/Sabbel.app $(INSTALL_APP_DIR)
	@echo "✓ Installed $(INSTALL_APP_DIR)"

reinstall-app: install-app ## Force a fresh app install after bundle changes

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
	@test -f $(CONFIG_DIR)/dictionary.toml || cp scripts/dictionary.example.toml $(CONFIG_DIR)/dictionary.toml
	@launchctl bootout $(LAUNCH_SERVICE) >/dev/null 2>&1 || true
	@launchctl bootstrap $(LAUNCH_DOMAIN) $(PLIST_PATH)
	@launchctl kickstart -k $(LAUNCH_SERVICE) >/dev/null
	@echo "✓ Sabbel will start on login and is running now."
	@echo "  Stop:    make stop"
	@echo "  Restart: make restart"
	@echo "  Reinstall after bundle changes: make reinstall-app"
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

setup-dictionary: ## Open dictionary for editing
	@mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/dictionary.toml || cp scripts/dictionary.example.toml $(CONFIG_DIR)/dictionary.toml
	@open -t $(CONFIG_DIR)/dictionary.toml

download-model: ## Pre-download Whisper model (~1.5GB)
	uv run python -c "import mlx_whisper, numpy as np; mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo='mlx-community/whisper-large-v3-turbo')"
	@echo "✓ Model cached."

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
