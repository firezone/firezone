# Creates a macOS debug build

PLATFORM=macOS
ARCH=$(shell uname -m)

# Set consistent environment to prevent Rust rebuilds
# This must match the Xcode project setting
export MACOSX_DEPLOYMENT_TARGET=12.4

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
