# Creates a macOS debug build

PLATFORM=macOS
ARCH=$(shell uname -m)

build-macos:
	echo "Building debug build for ${PLATFORM}, ${ARCH}"
	cd ../../rust/apple-client-ffi && rm -rf ./Connlib.xcframework && ./build-rust.sh && ./build-xcframework-dev.sh
	@xcodebuild build -scheme Firezone -sdk macosx -destination 'platform=${PLATFORM},arch=${ARCH}'

# Set consistent environment to prevent Rust rebuilds
# This must match the Xcode project setting
export MACOSX_DEPLOYMENT_TARGET=12.4

clean:
	@xcodebuild clean -scheme Firezone -sdk macosx -destination 'platform=${PLATFORM},arch=${ARCH}'
	cd ../../rust/apple-client-ffi && rm -rf ./Connlib.xcframework

.PHONY: format
format:
	@swiftformat .
