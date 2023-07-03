PLATFORM_MACOS = macOS,arch=x86_64
build-macos:
	@xcodebuild build \
		-workspace Firezone.xcworkspace \
		-scheme Firezone \
		-destination platform="$(PLATFORM_MACOS)"


.PHONY: format
format:
	@swiftformat .

