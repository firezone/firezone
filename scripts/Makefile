# Format: Semver
# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949

# Release Instructions (Gateway/GUI/Headless)
# 1. Publish the appropriate drafted release on GitHub
# 2. Bump the appropriate version in this file
# 3. Run `make version`
# 4. Commit the changes
# 5. Open a PR with the changes
#
# Release Instructions (Apple/Android)
# 1. Run the Swift or Kotlin workflow on main. This will push a build to AppStore Connect or Firebase.
# 2. Create a new release in AppStore Connect or Firebase appropriately and submit.
# 3. When the release is approved and live, bump the appropriate version in this file.
#
# CI will prevent pushing assets to releases that are published, so you need to bump
# the relevant versions in order to push to a newly drafted release.

# Tracks the current version to use for generating download links and changelogs
current-apple-version = 1.3.6
current-android-version = 1.3.5
current-gateway-version = 1.4.0
current-gui-version = 1.3.9
current-headless-version = 1.3.4

# Tracks the next version to release for each platform
next-apple-version = 1.3.7
next-android-version = 1.3.6
next-gateway-version = 1.4.1
next-gui-version = 1.3.10
next-headless-version = 1.3.5

# macOS uses a slightly different sed syntax
ifeq ($(shell uname),Darwin)
  SEDARG := -i ''
else
  SEDARG := -i
endif

.PHONY: apple-version android-version gateway-version gui-version headless-version version

apple-version:
	@find website -type f -name "redirects.js" -exec sed $(SEDARG) -e '/mark:current-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-apple-version)/g;}' {} \;
	@find website -type f -name "route.ts" -exec sed $(SEDARG) -e '/mark:current-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-apple-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-apple-version)/g;}' {} \;
	@find swift -type f -name "project.pbxproj" -exec sed $(SEDARG) -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(next-apple-version);/' {} \;
	@find rust -path rust/gui-client/node_modules -prune -o -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-apple-version)/;}' {} \;
	@cd rust && cargo update --workspace

android-version:
	@find website -type f -name "redirects.js" -exec sed $(SEDARG) -e '/mark:current-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-android-version)/g;}' {} \;
	@find website -type f -name "route.ts" -exec sed $(SEDARG) -e '/mark:current-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-android-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-android-version)/g;}' {} \;
	@find kotlin -type f -name "*.gradle.kts" -exec sed $(SEDARG) -e '/mark:next-android-version/{n;s/versionName =.*/versionName = "$(next-android-version)"/;}' {} \;
	@find rust -path rust/gui-client/node_modules -prune -o -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-android-version)/;}' {} \;
	@cd rust && cargo update --workspace

gateway-version:
	@find website -type f -name "redirects.js" -exec sed $(SEDARG) -e '/mark:current-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-gateway-version)/g;}' {} \;
	@find website -type f -name "route.ts" -exec sed $(SEDARG) -e '/mark:current-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-gateway-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-gateway-version)/g;}' {} \;
	@find rust -path rust/gui-client/node_modules -prune -o -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-gateway-version)/;}' {} \;
	@cd rust && cargo update --workspace

gui-version:
	@find website -type f -name "redirects.js" -exec sed $(SEDARG) -e '/mark:current-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-gui-version)/g;}' {} \;
	@find website -type f -name "route.ts" -exec sed $(SEDARG) -e '/mark:current-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-gui-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-gui-version)/g;}' {} \;
	@find rust -path rust/gui-client/node_modules -prune -o -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-gui-version)/;}' {} \;
	@cd rust && cargo update --workspace

headless-version:
	@find website -type f -name "redirects.js" -exec sed $(SEDARG) -e '/mark:current-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-headless-version)/g;}' {} \;
	@find website -type f -name "route.ts" -exec sed $(SEDARG) -e '/mark:current-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(current-headless-version)/g;}' {} \;
	@find .github -name "*.yml" -exec sed $(SEDARG) -e '/mark:next-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-headless-version)/g;}' {} \;
	@find rust -path rust/gui-client/node_modules -prune -o -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/$(next-headless-version)/;}' {} \;
	@cd rust && cargo update --workspace

version: apple-version android-version gateway-version gui-version headless-version
