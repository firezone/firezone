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
    echo Administrator username will be: $adminEmail
  fi
}

# * checks to ensure wireguard is available (i.e. wireguard net devices can be added) (maybe there's a /sys file?)
function wireguardCheck() {
	if which wg > /dev/null; then
     echo $(wg --version) 
  else 
     echo "not installed"
     exit
	fi
}

# * checks to ensure kernel is > 4.19
function kernelCheck() {
   kernel_version=$(uname -r | cut -d- -f1 | cut -d. -f1)
   #may get really specific here
   if [ "$kernel_version" -ge "4" ]
   then
     echo "Kernel is supported"
   else
     echo "Kernel $kernel_version is not supported"
   fi
}

# * determines distro; aborts if it can't detect or is not supported
function determinDistro() {
  hostnamectl
}

promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:"
#wireguardCheck
#kernelCheck
#determinDistro
