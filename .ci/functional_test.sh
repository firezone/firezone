#!/usr/bin/env bash
set -x

# PORT is set in Github Actions matrix

echo "Trying to load homepage"
curl -i -vvv -k https://$(hostname):${PORT}/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):${PORT} -servername $(hostname) -showcerts -prexit
