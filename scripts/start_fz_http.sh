#!/usr/bin/env sh
set -e

# migrate DB
fz_http/bin/fz_http eval "FzHttp.Release.migrate"

# start app
fz_http/bin/fz_http start
