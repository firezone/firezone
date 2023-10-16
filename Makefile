# Format:
# MAJOR: This is the marketing version, e.g. 1. Don't change it.
# MINOR: This is the current version of the portal API in YYYYMMDD format. REST consumers will request
#        this API from the portal with the X-Firezone-API-Version request header.
#        Increment this for breaking API changes (e.g. once a quarter)
# PATCH: Increment this for each backwards-compatible release
# See discussion here: https://github.com/firezone/firezone/issues/2041
version = 2.0.0

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
