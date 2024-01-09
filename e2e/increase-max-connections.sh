#!/bin/sh

set -e

# This script is run before the service starts. See https://hub.docker.com/_/postgres

# We need to increase max_connections in the container's postgresql.conf file to allow for more connections.
# The default is 100, which is too low for our use case.
# We also need to increase shared_buffers to 512MB to allow for more connections.
sed -i "s/max_connections = 100/max_connections = 1000/g" /var/lib/postgresql/data/postgresql.conf
sed -i "s/shared_buffers = 128MB/shared_buffers = 512MB/g" /var/lib/postgresql/data/postgresql.conf
