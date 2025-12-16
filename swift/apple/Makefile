# Creates a macOS debug build

PLATFORM?=macOS
ARCH=$(shell uname -m)
CONFIGURATION?=Debug

# Paths
RUST_DIR=$(abspath ../../rust)
RUST_TARGET_DIR=$(RUST_DIR)/target
CLIENT_FFI_DIR=$(RUST_DIR)/client-ffi
GENERATED_DIR=$(abspath FirezoneNetworkExtension/Connlib/Generated)

# Find all Rust source files in client-ffi
CLIENT_FFI_SOURCES=$(shell find $(CLIENT_FFI_DIR)/src -name "*.rs" 2>/dev/null)

# Set consistent environment to prevent Rust rebuilds
# This must match the Xcode project setting
export MACOSX_DEPLOYMENT_TARGET=12.4

# Map architecture names for Rust targets
ifeq ($(ARCH),arm64)
	RUST_TARGET=aarch64-apple-darwin
else
	RUST_TARGET=x86_64-apple-darwin
endif

# Get the current Git SHA for build identification
GIT_SHA=$(shell git rev-parse HEAD 2>/dev/null || echo "unknown")

# Default target: build and install
.PHONY: all
all: uniffi-bindings build install

# Generate UniFFI bindings from Rust source
# This works on any platform (not just macOS)
$(GENERATED_DIR)/connlib.swift $(GENERATED_DIR)/connlibFFI.h: $(CLIENT_FFI_SOURCES) $(CLIENT_FFI_DIR)/Cargo.toml
	@echo "Generating UniFFI bindings..."
	@mkdir -p $(GENERATED_DIR)
	@cd $(RUST_DIR) && \
		cargo build -p client-ffi && \
		cargo run -p uniffi-bindgen -- generate \
			--library $(RUST_TARGET_DIR)/debug/libconnlib.a \
			--language swift \
			--out-dir $(GENERATED_DIR)
	@rm -f $(GENERATED_DIR)/*.modulemap
	@if [ -f "$(GENERATED_DIR)/connlib.swift" ]; then \
		sed -i.bak '/#if canImport(connlibFFI)/,/#endif/s/^/\/\/ /' $(GENERATED_DIR)/connlib.swift; \
		rm -f $(GENERATED_DIR)/connlib.swift.bak; \
	fi
	@echo "✅ UniFFI bindings generated"

.PHONY: uniffi-bindings
uniffi-bindings: $(GENERATED_DIR)/connlib.swift $(GENERATED_DIR)/connlibFFI.h

# Info for sourcekit-lsp (LSP server for other IDEs)
.PHONY: lsp
lsp:
	@if command -v xcode-build-server >/dev/null 2>&1; then \
		xcode-build-server config \
			-project Firezone.xcodeproj \
			-scheme Firezone; \
	else \
		echo "xcode-build-server not installed, skipping LSP configuration"; \
		echo "   Install with: brew install xcode-build-server"; \
	fi

.PHONY: build
build: $(GENERATED_DIR)/connlib.swift $(GENERATED_DIR)/connlibFFI.h
	@if [ ! -f buildServer.json ]; then \
		echo "buildServer.json not found, generating LSP configuration..."; \
		$(MAKE) lsp; \
	fi
	@echo "Building Xcode project for ${PLATFORM}, ${ARCH}"
	@echo "Git SHA: ${GIT_SHA}"
	@xcodebuild build \
		-project Firezone.xcodeproj \
		-scheme Firezone \
		-configuration $(CONFIGURATION) \
		-sdk macosx \
		-destination 'platform=${PLATFORM},arch=${ARCH}' \
		CONNLIB_TARGET_DIR="${RUST_TARGET_DIR}" \
		GIT_SHA="${GIT_SHA}" \
		ONLY_ACTIVE_ARCH=YES

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

.PHONY: test
test:
	@echo "Running FirezoneKit tests..."
	@cd FirezoneKit && swift test

.PHONY: clean
clean:
	@echo "Cleaning Xcode build"
	@xcodebuild clean \
		-project Firezone.xcodeproj \
		-scheme Firezone \
		-configuration $(CONFIGURATION) \
		-sdk macosx
	@echo "Cleaning Rust build artifacts"
	@cd ../../rust/client-ffi && cargo clean
	@echo "Removing generated bindings"
	@rm -rf FirezoneNetworkExtension/Connlib/Generated

.PHONY: format
format:
	@echo "Formatting Swift code..."
	@find . -name "*.swift" -not -path "./FirezoneNetworkExtension/Connlib/Generated/*" -not -path "./FirezoneKit/.build/*" | xargs swift format format --in-place --parallel
	@echo "Linting Swift code..."
	@find . -name "*.swift" -not -path "./FirezoneNetworkExtension/Connlib/Generated/*" -not -path "./FirezoneKit/.build/*" | xargs swift format lint --parallel --strict

.PHONY: setup
setup:
	@echo "Installing required Rust targets..."
	@rustup target add aarch64-apple-darwin x86_64-apple-darwin
	@rustup target add aarch64-apple-ios x86_64-apple-ios
	@echo "Setup complete!"

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
