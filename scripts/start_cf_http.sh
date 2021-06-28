#!/usr/bin/env sh
set -e

# migrate DB
fg_http/bin/fg_http eval "CfHttp.Release.migrate"

# start app
fg_http/bin/fg_http start
