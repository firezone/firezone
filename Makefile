# Format: Semver
# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949
version = 1.0.0

.PHONY: version

ifeq ($(shell uname),Darwin)
SEDARG := -i ''
else
SEDARG := -i
endif

version:
	@# Elixir can set its Application version from a file, but other components aren't so flexible.
	@echo $(version) > elixir/VERSION
	@find rust/ -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find .github/ -name "*.yml" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find swift/ -name "project.pbxproj" -exec sed $(SEDARG) -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(version);/' {} \;
	@find kotlin/ -name "*.gradle.kts" -exec sed $(SEDARG) -e '/mark:automatic-version/{n;s/versionName =.*/versionName = "$(version)"/;}' {} \;
	@cd rust && cargo check
