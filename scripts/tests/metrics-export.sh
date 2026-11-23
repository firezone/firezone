#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Only `otel-ingest-proxy` exports to the collector and only it sets `firezone.account.slug`.
function wait_for_collector_log() {
    timeout 120 bash -c "until docker compose logs otel | grep --quiet --fixed-strings '$1'; do sleep 1; done"
}

wait_for_collector_log "service.name: Str(client)"
wait_for_collector_log "service.name: Str(gateway)"
wait_for_collector_log "firezone.account.slug: Str(firezone)"
