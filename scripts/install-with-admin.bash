#!/bin/bash
# Add a bash script that:
#
# TODO
#  * latest release and matching artifact puzzel
# TODO
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
 curl --silent https://api.github.com/repos/firezone/firezone/releases/latest | grep '"browser_download_url"'
}

function installAndDownloadArtifact() {
  #this will be passed in once I determine the mapping of OS/Kernel to release artifact
  #url="https://github.com/firezone/firezone/releases/download/0.2.17/firezone_0.2.17-debian11-x64.deb"

  url="https://github.com/firezone/firezone/releases/download/0.2.17/firezone_0.2.17-fedora34-x64.rpm"
  file=$(basename $url)
  echo $file
  cd /tmp  
  wget $url
  if [[ "$url" =~ .*"deb".* ]]; then
    sudo dpkg -i $file
  else
    sudo rpm -i $file
  fi
}

function main() {
  adminUser=''
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:" adminUser

  #guard checks
  wgInstalledStatus=''
  wireguardCheck wgInstalledStatus 
  if [ "$wgInstalledStatus" == "not installed" ]; then
    echo "Wireguard is not installed. Quitting." 
    exit
  fi

  kernelStatus=''
  kernelCheck kernelStatus
  if [ "$kernelStatus" != "is supported" ]; then
    echo "$kernelStatus. Quitting." 
    exit
  fi

  #puzzle here but the discussion has begun
  #determinDistro
  #latestRelease

  echo "Press key to install..."
  read
  #after doing the mapping pass url here 
  #for now hardcoded
  installAndDownloadArtifact
  #sanity check or guard condition here too
  firezone-ctl create-or-reset-admin $adminUser
}

main

