version = 1.20231001.0

version:
	@find elixir/ -name "mix.exs" -exec sed -i '' -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find rust/ -name "Cargo.toml" -exec sed -i '' -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find .github/ -name "*.yml" -exec sed -i '' -e '/mark:automatic-version/{n;s/[0-9]*\.[0-9]*\.[0-9]*/$(version)/;}' {} \;
	@find swift/ -name "project.pbxproj" -exec sed -i '' -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(version);/' {} \;
	@find kotlin/ -name "build.gradle.kts" -exec sed -i '' -e '/mark:automatic-version/{n;s/versionName =.*/versionName = "$(version)"/;}' {} \;
	@cd rust && cargo check
