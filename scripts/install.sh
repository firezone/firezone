#!/bin/bash
set -e

telemetry_id=`od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo`
public_ip=`curl --silent ifconfig.me`

capture () {
  if type curl > /dev/null; then
    if [ ! -z "$telemetry_id" ]; then
      curl -s -XPOST \
        -H 'Content-Type: application/json' \
        -d "{
          \"api_key\": \"phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK\",
          \"event\": \"$1\",
          \"properties\": {
            \"distinct_id\": \"$telemetry_id\",
            \"email\": \"$2\"
          }
        }" \
        https://telemetry.firez.one/capture/ > /dev/null
    fi
  fi
}
promptEmail() {
  echo $1
  read adminEmail
  case $adminEmail in
    *@*) adminUser=$adminEmail;;
    *) promptEmail "Please provide a valid email: "
  esac
}

promptContact() {
  echo "Could we email you to ask for product feedback? Firezone depends heavily on input from users like you to steer development. (Y/n): "
  read contact
  case $contact in
    n);;
    N);;
    *) capture "contactOk" $adminUser
  esac
}

wireguardCheck() {
  if ! test -f /sys/module/wireguard/version; then
    if test -f `find /lib/modules/$(uname -r) -type f -name 'wireguard.ko'`; then
      echo "Wireguard kernel module found, but not loaded."
      echo "Load it with 'sudo modprobe wireguard' and run this install script again"
    else
      echo "Error! WireGuard not detected. Please upgrade your kernel to at least 5.6 or install the WireGuard kernel module."
      echo "See more at https://www.wireguard.com/install/"
    fi
    exit
  fi
}

kernelCheck() {
  major=`uname -r | cut -d'.' -f1`
  if [ "$major" -lt "5" ]; then
    echo "Kernel is not supported `uname -r`"
    exit
  fi
}

# * determines distro; aborts if it can't detect or is not supported
mapReleaseToDistro() {
  hostinfo=`hostnamectl | egrep -i '(opera|arch)'`
  image_sub_string=''
  if [[ "$hostinfo" =~ .*"Debian GNU/Linux 10".*   && "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="debian10-x64"
  elif [[ "$hostinfo" =~ .*"Debian GNU/Linux 10".* && "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="debian10-arm64"
  elif [[ "$hostinfo" =~ .*"Debian GNU/Linux 11".* && "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="debian11-x64"
  elif [[ "$hostinfo" =~ .*"Debian GNU/Linux 11".* &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="debian11-arm64"
  elif [[ "$hostinfo" =~ .*"Amazon Linux 2".*      &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="amazonlinux2-x64"
  elif [[ "$hostinfo" =~ .*"Amazon Linux 2".*      &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="amazonlinux2-arm64"
  elif [[ "$hostinfo" =~ .*"Fedora 33".*           &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="fedora33-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 33".*           &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="fedora33-arm64"
  elif [[ "$hostinfo" =~ .*"Fedora 34".*           &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="fedora34-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 34".*           &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="fedora34-arm64"
  elif [[ "$hostinfo" =~ .*"Fedora Linux 35".*     &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="fedora35-x64"
  elif [[ "$hostinfo" =~ .*"Fedora Linux 35".*     &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="fedora35-arm64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 18.04".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="ubuntu1804-x64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 18.04".*  &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="ubuntu1804-arm64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 20.04".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="ubuntu2004-x64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 20.04".*  &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="ubuntu2004-arm64"
  elif [[ "$hostinfo" =~ .*"CentOS Linux 7".*      &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="centos7-x64"
  elif [[ "$hostinfo" =~ .*"CentOS Stream 8".*     &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="centos8-x64"
  elif [[ "$hostinfo" =~ .*"CentOS Stream 8".*     &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="centos8-arm64"
  elif [[ "$hostinfo" =~ .*"CentOS Stream 9".*     &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="centos9-x64"
  elif [[ "$hostinfo" =~ .*"CentOS Stream 9".*     &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="centos9-arm64"
  elif [[ "$hostinfo" =~ .*"openSUSE Leap 15".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="opensuse15-x64"
  fi

  if [ -z "$image_sub_string" ]; then
    echo "Unsupported Operating System. Aborting."
    exit
  fi

  latest_release=`
    curl --silent https://api.github.com/repos/firezone/firezone/releases/latest |
    grep browser_download_url |
    cut -d: -f2,3 |
    sed 's/\"//g' |
    grep $image_sub_string
  `
  echo "url: "$latest_release
  eval "$1='$latest_release'" # return url to 1st param
}

installAndDownloadArtifact() {
  url=$1
  file=`basename $url`
  echo "Downloading: $url"
  cd /tmp
  curl --progress-bar -L $url --output $file
  echo "Installing: $file"
  if [[ "$url" =~ .*"deb".* ]]; then
    sudo dpkg -i $file
  else
    sudo rpm -i --force $file
  fi
}

firezoneSetup() {
  conf="/opt/firezone/embedded/cookbooks/firezone/attributes/default.rb"
  sudo sed -i "s/firezone@localhost/$1/" $conf
  sudo sed -i "s/default\['firezone']\['external_url'].*/default['firezone']['external_url'] = 'https:\/\/$public_ip'/" $conf
  sudo firezone-ctl reconfigure
  sudo firezone-ctl create-or-reset-admin
}

main() {
  adminUser=''
  wireguardCheck
  kernelCheck
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:"
  promptContact
  releaseUrl=''
  mapReleaseToDistro releaseUrl
  echo "Press <ENTER> to install or Ctrl-C to abort."
  read
  installAndDownloadArtifact $releaseUrl
  firezoneSetup $adminUser
}

capture "install" "email-not-collected@dummy.domain"
main
