#!/usr/bin/env sh

# migrate DB
cf_http/bin/cf_http eval "CfHttp.Release.migrate"

# start app
cf_http/bin/cf_http start
