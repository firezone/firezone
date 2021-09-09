#!/bin/bash
set -e

# XXX: Update this for Omnibus packages.

os_not_found () {
  echo "Operating System not detected. Build from source?"
  exit 1
}

download_release () {
  regex="Operating System: (\w+) ([\d\.]+)"
  os=`hostnamectl`
  if [[ $os =~ $regex ]]; then
    distro="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    if [[ -z $distro ]] && [[ -z $version ]]; then
      os_not_found
    else
      echo "Fetching latest release..."
      file="firezone-latest-${distro}_${version}.amd64.tar.gz"
      curl -L -O "https://github.com/firezone/firezone/releases/${file}"
    fi
  else
    os_not_found
  fi
}

echo "Installing FireZone..."
echo

if [ -n "$1" ]; then
  echo "Package tarball supplied. Skipping download..."
  file=$1
else
  download_release
fi

echo "Setting up FireZone..."
echo

if id firezone &>/dev/null; then
  echo "firezone user exists... not creating."
else
  echo "Creating system user firezone"
  useradd --system firezone
fi

echo "Extracting package to /opt/firezone..."
echo
tar -zxf $file -C /opt/
chmod -R firezone:firezone /opt/firezone

# Create DB user
echo "Creating DB user..."
hostname=$(hostname)
db_user=firezone
db_password="$(openssl rand -hex 16)"
res=$(su postgres -c "psql -c \"SELECT 1 FROM pg_roles WHERE rolname = '${db_user}';\"")
if [[ $res == *"0 rows"* ]]; then
  su postgres -c "psql -c \"CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}';\""
else
  echo "${db_user} role found in DB"
fi

# Create DB if not exists
db_name=firezone
res=$(su postgres -c "psql -c \"SELECT 1 FROM pg_database WHERE datname = '${db_name}';\"")
if [[ $res == *"0 rows"* ]]; then
  su postgres -c "psql -c \"CREATE DATABASE firezone;\" || true"
else
  echo "${db_name} exists; not creating"
fi




echo "FireZone installed successfully!"
