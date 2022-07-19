#!/bin/bash
set -e

osCheck () {
  os=`uname -s`
  if [ ! $os = "Linux" ]; then
    echo "Please ensure you're running this script on Linux and try again."
    exit
  fi
}

curlCheck () {
  if ! type curl > /dev/null; then
    echo 'curl not found. Please install curl to use this script.'
    exit
  fi
}

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
        https://telemetry.firez.one/capture/ > /dev/null \
        || true
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
    if test -d /lib/modules/$(uname -r) && test -f `find /lib/modules/$(uname -r) -type f -name 'wireguard.ko'`; then
      echo "WireGuard kernel module found, but not loaded."
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
    echo "Kernel version `uname -r ` is not supported. Please upgrade to 5.0 or higher."
    exit
  fi
}

# determines distro and sets up and installs from cloudsmith repo
# aborts if it can't detect or is not supported
setupCloudsmithRepoAndInstall() {
  hostinfo=`hostnamectl | egrep -i 'opera'`
  if [[ "$hostinfo" =~ .*"Debian GNU/Linux 10".* || \
        "$hostinfo" =~ .*"Debian GNU/Linux 11".* || \
        "$hostinfo" =~ .*"Ubuntu 18.04".*        || \
        "$hostinfo" =~ .*"Ubuntu 2"(0|1|2)".04".*
     ]]
  then
    if [ ! -f /etc/apt/sources.list.d/firezone-firezone.list ]; then
      setupCloudsmithRepo "deb"
    else
      apt-get -qqy update
    fi

    apt-get install -y firezone
  elif [[ "$hostinfo" =~ .*"Amazon Linux 2".*                   || \
          "$hostinfo" =~ .*"Fedora 33".*                        || \
          "$hostinfo" =~ .*"Fedora 34".*                        || \
          "$hostinfo" =~ .*"Fedora Linux 3"(5|6).*              || \
          "$hostinfo" =~ .*"CentOS Linux 7".*                   || \
          "$hostinfo" =~ .*"CentOS Stream 8".*                  || \
          "$hostinfo" =~ .*"CentOS Linux 8".*                   || \
          "$hostinfo" =~ .*"CentOS Stream 9".*                  || \
          "$hostinfo" =~ .*"Oracle Linux Server "(7|8|9).*      || \
          "$hostinfo" =~ .*"Red Hat Enterprise Linux "(7|8|9).* || \
          "$hostinfo" =~ .*"Rocky Linux 8".*                    || \
          "$hostinfo" =~ .*"AlmaLinux 8".*                      || \
          "$hostinfo" =~ .*"VzLinux 8".*
       ]]
  then
    if [ ! -f /etc/yum.repos.d/firezone-firezone.repo ]; then
      setupCloudsmithRepo "rpm"
    fi

    yum install -y firezone
  elif [[ "$hostinfo" =~ .*"openSUSE Leap 15".* ]]
  then
    if ! zypper lr | grep firezone-firezone; then
      setupCloudsmithRepo "rpm"
    else
      zypper --non-interactive --quiet ref firezone-firezone
    fi

    zypper --non-interactive install -y firezone
  else
    echo "Did not detect a supported Linux distribution. Try using the manual installation method using a release package from a similar distribution. Aborting."
    exit
  fi
}

setupCloudsmithRepo() {
  curl -1sLf \
    "https://dl.cloudsmith.io/public/firezone/firezone/setup.$1.sh" \
    | bash
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
  kernelCheck
  wireguardCheck
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:"
  promptContact
  echo "Press <ENTER> to install or Ctrl-C to abort."
  read
  setupCloudsmithRepoAndInstall
  firezoneSetup $adminUser
}

osCheck
curlCheck

telemetry_id=`od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo`
public_ip=`curl --silent ifconfig.me`

capture "install" "email-not-collected@dummy.domain"

main
