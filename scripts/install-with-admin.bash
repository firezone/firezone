#!/bin/bash
# Add a bash script that:
#
# * downloads latest release
# * installs it with `dpkg -i` or `rpm -i`
# * creates the first admin user with `firezone-ctl create-or-reset-admin ${admin_email}`
#
# Prompt for admin email should be along the lines of:
#
# `Enter the administrator email you'd like to use for logging into this Firezone instance:`
#
# Sanity check by making sure input has a `@`
#
# The `create-or-reset-admin` command will need to be updated to optionally accept an email argument.

# * prompts user for admin email
function promptEmail() {
  echo $1
  read adminEmail
  if [[ $adminEmail != *[@]* ]]
  then
    promptEmail "please provide a valid email"
  else
    #echo Administrator username will be: $adminEmail
    eval "$2='$adminEmail'"
  fi
}

# * checks to ensure wireguard is available (i.e. wireguard net devices can be added) (maybe there's a /sys file?)

function wireguardCheck() {
	if which wg > /dev/null; then
     eval "$1='$(wg --version)'"
  else 
     eval "$1='not installed'"
	fi
}

# * checks to ensure kernel is > 4.19
function kernelCheck() {
   kernel_version=$(uname -r | cut -d- -f1 | cut -d. -f1)
   #trying to avoid _yuge_ if-else here so just starting with the top number >= for now
   #may need to review linux versions and test a slew of comparisons
   if [ "$kernel_version" -ge "4" ]
   then
     eval "$1='is supported'"
   else
     eval "$1='\'$kernel_version\': is not supported'"
   fi
}

# * determines distro; aborts if it can't detect or is not supported
function determinDistro() {
  hostnamectl
}


function latestRelease() {
 #based on the os type we only need the specific artifact url
 curl --silent https://api.github.com/repos/firezone/firezone/releases/latest | grep '"browser_download_url"'
}


promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:", adminUser

#guard checks
wireguardCheck wgInstalledStatus 
if [ "$wgInstalledStatus" == "not installed" ]; then
  echo "Wireguard is not installed. Quitting." 
  exit
fi

kernelCheck kernelStatus
if [ "$kernelStatus" != "is supported" ]; then
  echo "$kernelStatus. Quitting." 
  exit
fi

determinDistro

latestRelease
