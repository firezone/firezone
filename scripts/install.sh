#!/bin/bash
set -e

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

echo "Extracting package to /opt/firezone..."
tar -zxf $file -C /opt/

echo "FireZone installed!"
