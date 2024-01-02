# Maintainer's Guide

This document contains instructions for maintaining the code in this repo
including the product, website, and documentation.

Table of Contents:

- [Releasing](#releasing)
- [Publishing Clients](#publishing-clients)
  - [Apple Client](#apple-client)

## Releasing

**Note**: The version gets set from the Makefile

- Go to Actions tab in GH

  - For apple the workflow is `Swift`
  - For Android the workflow is `Kotlin`

- Click the edit button on the Draft 1.0.0 release
- Give the release a name (manually - right now we're using
  `1.0.0-pre.<num-here>`)
- Create a new tag as well with the same name as the release (click
  `create new tag`)
- Double check that the body text of the release is what is expected
- **IMPORTANT**: Scroll to the bottom and check the `Set as latest release` and
  uncheck `Set as pre-release`
- Click `Publish Release`
- The `Publish` workflow is now run Note: This will deploy to production and the
  following will happen
  - All logged in users on the portal will be logged out, but the clients will
    not be logged out
  - All the websockets will be disconnected and should automatically reconnect

## Publish Clients

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
