# Format: Semver
# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949

# Release Instructions:
# 1. Publish the appropriate drafted release on GitHub
# 2. Bump the appropriate version in this file
# 3. Run `make version`
# 4. Commit the changes
# 5. Open a PR with the changes
#
# CI will prevent pushing assets to releases that are published, so you need to bump
# the relevant versions in order to push to a newly drafted release.

# Tracks the current version to use for generating download links and changelogs
current-apple-version = 1.0.4
current-android-version = 1.0.2
current-gateway-version = 1.0.6
current-gui-version = 1.0.6
current-headless-version = 1.0.6

# Tracks the next version to release for each platform
next-apple-version = 1.0.5
next-android-version = 1.0.3
next-gateway-version = 1.1.0
next-gui-version = 1.0.7
next-headless-version = 1.0.7

# macOS uses a slightly different sed syntax
ifeq ($(shell uname),Darwin)
SEDARG := -i ''
else
SEDARG := -i
endif

.PHONY: apple-version android-version gateway-version gui-version headless-version version

# Update website changelog and docs to current version and Xcode project file to next version
apple-version:
	@find ./website -path ./website/node_modules -prune -o -path ./website/.next -prune -o -type f -o -exec sed $(SEDARG) -e '/mark:current-apple-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(current-apple-version)/g;}' {} \;
	@find swift -type f -name "project.pbxproj" -o -exec sed $(SEDARG) -e 's/MARKETING_VERSION = .*;/MARKETING_VERSION = $(next-apple-version);/' {} \;

# Update website changelog to current version and Gradle files to next version
android-version:
	@find website -path website/node_modules -prune -o -path website/.next -prune -o -type f -exec sed $(SEDARG) -e '/mark:current-android-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(current-android-version)/g;}' {} \;
	@find kotlin -type f -name "*.gradle.kts" -exec sed $(SEDARG) -e '/mark:next-android-version/{n;s/versionName =.*/versionName = "$(next-android-version)"/;}' {} \;

# Update website changelog and DL links to current version and cargo files, CI release to next version
gateway-version:
	@# The website hosts permalinks to our published packages and binaries
	@find website -path website/node_modules -prune -o -path website/.next -prune -o -type f -exec sed $(SEDARG) -e '/mark:current-gateway-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(current-gateway-version)/g;}' {} \;	
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-gateway-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(next-gateway-version)/g;}' {} \;

# Update website changelog and DL links to current version and cargo files, CI release to next version
gui-version:
	@# The website hosts permalinks to our published packages and binaries
	@find website -path website/node_modules -prune -o -path website/.next -prune -o -type f -exec sed $(SEDARG) -e '/mark:current-gui-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(current-gui-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-gui-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(next-gui-version)/g;}' {} \;
	@find rust -type f -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-gui-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(next-gui-version)/;}' {} \;
	@cd rust && cargo update --workspace

# Update website changelog and DL links to current version and cargo files, CI release to next version
headless-version:
	@# The website hosts permalinks to our published packages and binaries
	@find website -path website/node_modules -prune -o -path website/.next -prune -o -type f -exec sed $(SEDARG) -e '/mark:current-headless-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(current-headless-version)/g;}' {} \;
	@find .github -type f -exec sed $(SEDARG) -e '/mark:next-headless-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(next-headless-version)/g;}' {} \;
	@find rust -type f -name "Cargo.toml" -exec sed $(SEDARG) -e '/mark:next-headless-version/{n;s/[0-9]+\.[0-9]+\.[0-9]+/$(next-headless-version)/;}' {} \;
	@cd rust && cargo update --workspace

version: apple-version android-version gateway-version gui-version headless-version

