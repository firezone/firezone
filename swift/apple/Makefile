# Creates a macOS debug build

PLATFORM=macOS
ARCH=$(shell uname -m)

# Set consistent environment to prevent Rust rebuilds
# This must match the Xcode project setting
export MACOSX_DEPLOYMENT_TARGET=12.4

# Info for sourcekit-lsp (LSP server for other IDEs)
lsp:
	@xcode-build-server config \
        -project Firezone.xcodeproj \
        -scheme Firezone

build-macos:
	echo "Building debug build for ${PLATFORM}, ${ARCH}"
	cd ../../rust/apple-client-ffi && rm -rf ./Connlib.xcframework && ./build-rust.sh && ./build-xcframework-dev.sh
	@xcodebuild build -scheme Firezone -sdk macosx -destination 'platform=${PLATFORM},arch=${ARCH}'


.PHONY: install
install:
	@echo "Stopping any running Firezone instances..."
	@-osascript -e 'tell application "Firezone" to quit' 2>/dev/null || true
	@-pkill -x Firezone 2>/dev/null || true
	@echo "Stopping and removing Firezone network extension..."
	@-sudo pkill -f "Firezone.NetworkExtension" 2>/dev/null || true
	@-sudo systemextensionsctl uninstall 47R2M6779T dev.firezone.firezone.network-extension 2>/dev/null || true
	@-sudo systemextensionsctl uninstall 47R2M6779T dev.firezone.firezone.network-extension-systemextension 2>/dev/null || true
	@sleep 2
	@echo "Copying app to /Applications..."
	@sudo cp -R ~/Library/Developer/Xcode/DerivedData/Firezone-*/Build/Products/$(CONFIGURATION)/Firezone.app /Applications/
	@echo "Launching Firezone..."
	@open /Applications/Firezone.app

clean:
	@xcodebuild clean -scheme Firezone -sdk macosx -destination 'platform=${PLATFORM},arch=${ARCH}'
	cd ../../rust/apple-client-ffi && rm -rf ./Connlib.xcframework

.PHONY: format
format:
	@echo "Formatting Swift code..."
	@find . -name "*.swift" -not -path "./FirezoneNetworkExtension/Connlib/Generated/*" -not -path "./FirezoneKit/.build/*" | xargs swift format format --in-place --parallel
	@echo "Linting Swift code..."
	@find . -name "*.swift" -not -path "./FirezoneNetworkExtension/Connlib/Generated/*" -not -path "./FirezoneKit/.build/*" | xargs swift format lint --parallel --strict
.PHONY: show-client-log
show-client-log:
	@echo "Opening latest Firezone client log..."
	@latest_log=$$(find ~/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/app -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1); \
	if [ -n "$$latest_log" ]; then \
		less "$$latest_log"; \
	else \
		echo "No log files found"; \
	fi

.PHONY: tail-client-log
tail-client-log:
	@echo "Tailing latest Firezone client log..."
	@latest_log=$$(find ~/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/app -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1); \
	if [ -n "$$latest_log" ]; then \
		tail -f "$$latest_log"; \
	else \
		echo "No log files found"; \
	fi

.PHONY: show-client-log-pretty
show-client-log-pretty:
	@echo "Opening latest Firezone client log (formatted)..."
	@latest_log=$$(find ~/Library/Group\ Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/app -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1); \
	if [ -n "$$latest_log" ]; then \
		jq -r '[.timestamp, .level, .message] | @tsv' "$$latest_log" | less; \
	else \
		echo "No log files found"; \
	fi

.PHONY: show-ext-log
show-ext-log:
	@echo "Showing Firezone Network Extension logs from system console (last 30 minutes)..."
	@log show --predicate 'process CONTAINS "dev.firezone.firezone.network-extension" OR (subsystem CONTAINS "dev.firezone" AND process != "Firezone")' --last 30m | less

.PHONY: tail-ext-log
tail-ext-log:
	@echo "Following Firezone Network Extension logs..."
	@log stream --predicate 'process CONTAINS "dev.firezone.firezone.network-extension" OR (subsystem CONTAINS "dev.firezone" AND process != "Firezone")'

.PHONY: show-all-logs
show-all-logs:
	@echo "Showing all Firezone logs from system console (last 30 minutes)..."
	@log show --predicate '(process CONTAINS "Firezone" OR subsystem CONTAINS "dev.firezone") AND process != "codebook-lsp"' --last 30m | less

.PHONY: tail-all-logs
tail-all-logs:
	@echo "Following all Firezone logs (including connlib from file)..."
	@# Stream console logs in background
	@log stream --predicate '(process CONTAINS "Firezone" OR subsystem CONTAINS "dev.firezone" OR category == "connlib") AND process != "codebook-lsp"' &
	@# Also tail connlib log file if accessible
	@if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" ]; then \
		tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"; \
	else \
		echo "Note: connlib file logs require sudo access. Run 'make tail-connlib' with sudo for file logs."; \
		wait; \
	fi

.PHONY: show-connlib-log
show-connlib-log:
	@echo "Viewing connlib log (requires sudo)..."
	@if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" ]; then \
		less "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"; \
	else \
		sudo less "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"; \
	fi

.PHONY: tail-connlib-log
tail-connlib-log:
	@echo "Following connlib log (requires sudo)..."
	@if [ -r "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest" ]; then \
		tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"; \
	else \
		sudo tail -f "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/connlib/latest"; \
	fi

.PHONY: show-tunnel-log
show-tunnel-log:
	@echo "Viewing latest tunnel log (requires sudo)..."
	@latest_log=$$(sudo find "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/tunnel" -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1); \
	if [ -n "$$latest_log" ]; then \
		sudo less "$$latest_log"; \
	else \
		echo "No tunnel log files found"; \
	fi

.PHONY: tail-tunnel-log
tail-tunnel-log:
	@echo "Following latest tunnel log (requires sudo)..."
	@latest_log=$$(sudo find "/private/var/root/Library/Group Containers/47R2M6779T.dev.firezone.firezone/Library/Caches/logs/tunnel" -name "*.jsonl" -print0 2>/dev/null | xargs -0 ls -t | head -1); \
	if [ -n "$$latest_log" ]; then \
		sudo tail -f "$$latest_log"; \
	else \
		echo "No tunnel log files found"; \
	fi
