# Maintainer's Guide

This document contains instructions for maintaining the code in this repo
including the product and its documentation. The marketing website and product
docs live in the separate [firezone/website](https://github.com/firezone/website)
repository.

Table of Contents:

- [Releasing](#releasing)
- [Apple Client](#apple-client)
- [Breaking API Changes](#breaking-api-changes)

## Releasing

**Note**: The version for all published components is set from [scripts/bump-versions.sh](../scripts/bump-versions.sh).

### App Store clients (Apple/Android)

1. Run the [`Kotlin`](../.github/workflows/_kotlin.yml) or
   [`Swift`](../.github/workflows/_swift.yml) workflow from `main` as
   appropriate.
1. Test the resulting Firebase App Distribution or TestFlight build.
1. Submit the release for review:
   - For Apple, follow the [Apple client](#apple-client) instructions below.
   - For Android, download the AAB from Firebase App Distribution, create a new
     release in Google Play Console, and upload the AAB.

### GitHub-released components (Linux, Windows, and Gateway)

Given that `main` is tested:

1. Go to the draft release of the component you want to publish
1. Double-check that the assets attached are from a recent CI and include the
   correct changes.
1. Publish the release. Tags and release name should be auto generated. This will trigger pushing Docker images to `ghcr.io`.
1. Publishing the release triggers the `Publish release` workflow ([.github/workflows/publish-release.yml](../.github/workflows/publish-release.yml)), which opens two version-bump PRs automatically:
   1. In this repo: propagates the new version across the product via `scripts/bump-versions.sh`.
   1. In [firezone/website](https://github.com/firezone/website): converts the component's `<Unreleased>` changelog section into a dated entry and updates the displayed version markers (`src/app/api/releases/route.ts`, `redirects.js`).
1. Review and merge both PRs. Edit the release notes in the website PR's changelog entry if the drafted notes need changes.
1. Update the known issues in `firezone/website` under `src/app/kb/client-apps/*` as needed.
1. When the website PR merges and deploys, the site redirects to the new version(s).

This results in a gap where GitHub knows about the release but nobody else does.
This is okay because we can undo the GitHub release, and it prevents any queued PRs
from landing in the release while you execute this process.

### Apple Client

#### App Store release

1. Run the [`Swift`](../.github/workflows/_swift.yml) workflow from `main`. It
   uploads the iOS and macOS builds and updates the GitHub draft.
1. After QA passes, run the
   [`Submit Apple release`](../.github/workflows/submit-apple-release.yml)
   workflow from `main`.
1. When `prepare` finishes, inspect both versions through the pending
   `app-store` deployment link. Cancel the workflow if another build is needed,
   or approve it to submit both versions with manual release.

Required repository secrets:

- `APPLE_APP_STORE_CONNECT_MARKETING_API_KEY_ID`
- `APPLE_APP_STORE_CONNECT_MARKETING_API_KEY`

Required secrets in the reviewer-protected `app-store` GitHub Environment:

- `APPLE_APP_STORE_CONNECT_APP_MANAGER_API_KEY_ID`
- `APPLE_APP_STORE_CONNECT_APP_MANAGER_API_KEY`

#### TestFlight groups

- Log in to the following URL: https://appstoreconnect.apple.com/
- Go to Apps
- Go to Firezone
- Click on TestFlight
  - Note: You can't delete a `Version` in TestFlight
- There is "internal testing" and "external testing"
  - "internal testing" is only the Firezone team
  - "external testing" is the beta customers
- Click on the testing group you want to release to and on the testing group
  page:
  - Click the `+` on the `Builds` sections
  - Select the build you want to push out
  - Check the `Automatically notify testers`
  - Type a description of what you want users to see in the notification sent to
    users (e.g. a small change log of what's in this release)
  - Click `Submit for Review`
    - Then you have to wait for it to be reviewed (has been a matter of minutes
      as of late)

(Alternative way to push out a release)

- After login go to `Builds` (select either ios/macos)
- Find the `Version` section you want to release and drop down to show list of
  builds
- Find the build you want to push out, hover over the `Groups` column and select
  the `+` icon
- From here it's the same as the instructions above to type a description,
  etc...

## Breaking API changes

We should notify customers **2 weeks in advance** for any API-breaking changes.
