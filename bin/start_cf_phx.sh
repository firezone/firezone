#!/usr/bin/env sh

# migrate DB
cf_phx/bin/cf_phx eval "CfPhx.Release.migrate"

# start app
cf_phx/bin/cf_phx start
