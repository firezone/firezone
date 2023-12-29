# Maintainer's Guide

This document contains instructions for maintaining the code in this repo
including the product, website, and documentation.

Table of Contents:

- [QA Testing](#qa-testing)
  - [List of Test Cases](#list-of-test-cases)
- [Releasing](#releasing)
- [Publishing Clients](#publishing-clients)
  - [Apple Client](#apple-client)

## QA Testing

Unfortunately, due to the nature of a product like Firezone, it's not easy to
write automated end-to-end tests for every scenario. Some manual QA testing is
required before publishing a new release. This section aims to provide a QA test
case checklist for critical workflows that will be used to make a Go or No Go
decision for whether to ship a release.

Each test case will have the following format:

- **ID**: A short, unique identifier we can use to communicate about this test
  case internally.
- **Component Under Test**: The relevant component(s) to be tested by this test
  case.
- **Preconditions**: Required state of Firezone and network environment to be in
  before the test case is run.
- **Steps**: The actual actions to perform to evaluate the test case.
- **Expected Outcome**: The result that would make this test PASS
- **Actual Outcome**: PASS/FAIL status of the test case, with a descriptive log
  in the case of failure.

### List of Test Cases

Test cases should be executed in the order shown below unless otherwise noted.

- [portal-google-auth](#portal-google-auth)
- [portal-google-sync](#portal-google-sync)
- [portal-oidc-auth](#portal-oidc-auth)
- [portal-email-auth](#portal-google-auth)
- [client-google-auth](#client-google-auth)
- [client-oidc-auth](#client-oidc-auth)
- [client-email-auth](#client-email-auth)

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
