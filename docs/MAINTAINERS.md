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

1. Go to Actions tab in GH and run the `Kotlin` or `Swift` workflow appropriately
1. This pushes new release builds to Google Play internal testing or TestFlight.
1. Test this build manually a bit since we have no automated client tests yet
1. To submit for review:
   - For Apple, do this through AppStore connect. Details are [below](#apple-client).
   - For Android, run the [Submit Android release](../.github/workflows/submit-android-release.yml)
     workflow on `main`. Its `prepare` job verifies the exact GitHub draft, source
     commit, screenshots, and completed internal release, then writes a summary
     with the Play version code and links. Review that summary and the
     [Play Console](https://play.google.com/console/), then approve the
     `google-play` environment as an intentional reminder and
     checkpoint. After approval, the workflow revalidates the draft, replaces
     the screenshots, promotes the exact internal version to production, and
     submits both in one Google Play edit. If the draft changed while approval
     was pending, start a new workflow run. Managed Publishing holds approved
     changes until they are published manually.

The `prepare` job uses the existing testing-only
`play-store-publisher@firezone-55040.iam.gserviceaccount.com` service account to
inspect the internal track through a temporary edit, which it always discards.
After approval, the workflow uses GitHub OIDC to impersonate
`play-store-production-publisher@firezone-55040.iam.gserviceaccount.com`. Limit
that service account to the Firezone app in Play Console and grant only the
permissions needed to read releases, release to production, and manage the store
listing. Before the first workflow dispatch, explicitly create the `google-play`
GitHub environment. GitHub otherwise creates a referenced environment without
protection. Add required reviewers, restrict deployments to `main`, and set its
`GOOGLE_PLAY_ENVIRONMENT_CONFIGURED` variable to `true`. Restrict the Workload
Identity Federation subject to
`repo:firezone/firezone:environment:google-play`. Keep
[Managed Publishing](https://support.google.com/googleplay/android-developer/answer/9859654)
enabled.

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
