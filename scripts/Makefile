# Format: Semver
# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949

# These should track the upcoming release for Apple/Android
apple-version = 1.0.5
android-version = 1.0.3

# Set this to the current latest published release for the Windows/Linux/Gateway packages so
# that links from the website will work
website-version = 1.0.3

# Set this to the upcoming release for the Windows/Linux/Gateway packages
cargo-version = 1.0.4
elixir-version = 1.0.4
ci-version = 1.0.4

.PHONY: version apple-version android-version cargo-version ci-version elixir-version

ifeq ($(shell uname),Darwin)
SEDARG := -i ''
else
SEDARG := -i
endif

apple-version:
	@find swift/ -name "project.pbxproj" -exec sed $(SEDARG) -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(apple-version);/' {} \;

android-version:
	@find kotlin/ -name "*.gradle.kts" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/versionName =.*/versionName = "$(android-version)"/;}' {} \;

website-version:
	@# The website hosts permalinks to our published packages and binaries
	@find website/ -name "redirects.js" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(website-version)/g;}' {} \;

cargo-version:
	@find rust/ -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(cargo-version)/;}' {} \;
	@cd rust && cargo update --workspace

ci-version:
	@find .github/ -name "*.yml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(ci-version)/;}' {} \;

elixir-version:
	@# Elixir can set its Application version from a file, but other components aren't so flexible.
	@echo $(elixir-version) > elixir/VERSION

version: apple-version android-version cargo-version ci-version elixir-version website-version
