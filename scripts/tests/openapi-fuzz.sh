#!/usr/bin/env bash

# Fuzzes the REST API from its OpenAPI spec with Schemathesis. Every operation
# gets generated requests, valid and invalid, and every response is checked
# for server errors, undeclared status codes, wrong content types, bodies that
# do not match the schema, and invalid requests that were accepted anyway.
#
# Expects a portal seeded with `mix ecto.seed`, which creates the API token
# below, and raises the seeded account's API rate limit so the 429s do not
# drown out real findings. Set FIREZONE_API_URL to point at it.
#
# The Host header matches API_EXTERNAL_URL in docker-compose.yml, otherwise the
# portal redirects every request to its canonical host.
#
# Connections are not reused: for binary request bodies the client can send
# a Content-Length shorter than the body, and the leftover bytes then corrupt
# the next request on the same connection and show up as bogus failures.

set -euo pipefail

# The portal routes its replies through the portal-router, so it is reachable
# only from inside the compose network. Without Docker (see SCHEMATHESIS
# below) the caller points FIREZONE_API_URL at a portal it can reach directly.
api_url="${FIREZONE_API_URL:-http://portal:8081}"

# Encodes the token seeded for the "OpenAPI Fuzzer" actor, see
# elixir/priv/repo/seeds.exs.
api_token="${FIREZONE_API_TOKEN:-.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkNGMyZDlhMGUtN2Y2Yi00ZTFjLThhM2QtMmI1YzZkN2U4ZjkwbQAAADlPUEVOQVBJRlVaWjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDBuBgAZuRVloAFiAAFRgA.VJ6XQPTi359wnb07i6OH3lvgFY7_IeyqUEhr0tTEhh8}"

spec="elixir/priv/static/openapi.json"
report_dir="${SCHEMATHESIS_REPORT_DIR:-schemathesis-report}"

# SCHEMATHESIS overrides how the CLI is invoked, e.g. `uvx schemathesis==4.25.2`
# for a local run without Docker.
if [[ -n "${SCHEMATHESIS:-}" ]]; then
  # shellcheck disable=SC2206
  schemathesis=($SCHEMATHESIS)
  spec_path="$spec"
else
  schemathesis=(
    docker run --rm --network firezone_app-internal
    --user "$(id -u):$(id -g)"
    --volume "$PWD/$spec:/openapi.json:ro"
    --volume "$PWD/$report_dir:/report"
    schemathesis/schemathesis:4.25.2
  )
  spec_path="/openapi.json"
  report_dir="/report"
  mkdir -p schemathesis-report
fi

"${schemathesis[@]}" run "$spec_path" \
  --url "$api_url" \
  --header "Authorization: Bearer $api_token" \
  --header "Host: localhost:8081" \
  --header "Connection: close" \
  --checks not_a_server_error,status_code_conformance,content_type_conformance,response_schema_conformance,negative_data_rejection,ignored_auth \
  --max-examples "${SCHEMATHESIS_MAX_EXAMPLES:-25}" \
  --max-failures 25 \
  --workers 2 \
  --request-timeout 30 \
  --report junit \
  --report-dir "$report_dir" \
  --no-color
