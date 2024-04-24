# Format: Semver
# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949
apple-version = 1.0.3
android-version = 1.0.2
cargo-version = 1.0.1
website-version = 1.0.0
elixir-version = 1.0.1
ci-version = 1.0.1

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
	@find website/ -name "redirects.js" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(cargo-version)/g;}' {} \;

cargo-version:
	@find rust/ -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(cargo-version)/;}' {} \;
	@cd rust && cargo update --workspace

ci-version:
	@find .github/ -name "*.yml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(ci-version)/;}' {} \;

elixir-version:
	@# Elixir can set its Application version from a file, but other components aren't so flexible.
	@echo $(elixir-version) > elixir/VERSION

version: apple-version android-version cargo-version ci-version elixir-version website-version
