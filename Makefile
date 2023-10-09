# Format:
# MAJOR: This is the current version of the portal API in YYYYMMDD format. REST consumers will request
#        this API from the portal with the X-Firezone-API-Version request header.
# MINOR: Increment this each time you want to publish a new Firezone release
# PATCH: Unused for now
version = 20231001.0.0

.PHONY: version

version:
	@# Elixir can set its Application version from a file, but other components aren't so flexible.
	@echo $(version) > elixir/VERSION
	@find rust/ -name "Cargo.toml" -exec sed -i '' -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find .github/ -name "*.yml" -exec sed -i '' -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find swift/ -name "project.pbxproj" -exec sed -i '' -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(version);/' {} \;
	@find kotlin/ -name "build.gradle.kts" -exec sed -i '' -e '/mark:automatic-version/{n;s/versionName =.*/versionName = "$(version)"/;}' {} \;
	@cd rust && cargo check
