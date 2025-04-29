#!/bin/sh
set -e

CONF_FILE=$(find /var/lib/postgresql/data -name postgresql.conf -print -quit)

if [ -z "$CONF_FILE" ]; then
  echo "ERROR: postgresql.conf not found!"
  exit 1
fi

echo "Modifying $CONF_FILE to set wal_level=logical"

# Use sed to find the wal_level line (commented or uncommented) and replace it
# This is safer than appending, as it avoids duplicate settings.
sed -i "s/^#*wal_level = .*$/wal_level = logical/" "$CONF_FILE"

echo "wal_level set successfully."
