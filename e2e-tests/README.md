# E2E testing

Tests that the whole thing is working, using the portal's REST API + the gateway.

These tests depends on having 2 internal clients and 2 external servers and testing that all the connections work.

## How to run

From the root directory
`docker compose -f ./docker-compose.e2e.yml build`
`./scripts/e2e-tests.sh`

## TODO

* Integrate with CI.
* Improve error reporting.
* Take the orchestrator out of the docker-compose and have it start the client/server containers instead of depending on pre-defined ones.
* Maybe use [cargo-chef](https://crates.io/crates/cargo-chef) to speed up builds.
* More tests...
