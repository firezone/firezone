#!/bin/bash
# TODO
#  - [ ] The `create-or-reset-admin` command will need to be updated to optionally accept an email argument.

promptEmail() {
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

wireguardCheck() {
  if [[ -z "$(sudo find /sys -name "*wireguard*")" ]]; then
    echo "Error! WireGuard not detected. Please upgrade your kernel to at least 5.6 or install the WireGuard kernel module."
    echo "See more at https://www.wireguard.com/install/"
    exit
  fi
}

kernelCheck() {
   kernel_version=$(uname -r | cut -d- -f1 | cut -d. -f1)
   if [ "$kernel_version" -ge "4" ]
   then
     eval "$1='is supported'"
   else
     eval "$1='\'$kernel_version\': is not supported'"
   fi
}

# * determines distro; aborts if it can't detect or is not supported
mapReleaseToDistro() {
  hostinfo=$(hostnamectl | egrep -i '(opera|arch)')
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
     image_sub_string="fedora33-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 34".*           &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="fedora34-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 34".*           &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="fedora34-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 35".*           &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="fedora35-x64"
  elif [[ "$hostinfo" =~ .*"Fedora 35".*           &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="fedora35-x64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 18.04.6 LTS".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="ubuntu1804-x64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 18.04.6 LTS".*  &&  "$hostinfo" =~ .*"arm64" ]]; then
     image_sub_string="ubuntu1804-arm64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 20.04.3 LTS".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="ubuntu2004-x64"
  elif [[ "$hostinfo" =~ .*"Ubuntu 20.04.3 LTS".*  &&  "$hostinfo" =~ .*"arm64" ]]; then
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
  elif [[ "$hostinfo" =~ .*"openSUSE Leap 15.3".*  &&  "$hostinfo" =~ .*"x86" ]]; then
     image_sub_string="opensuse15-x64"
  fi

  echo hello: $image_sub_string
  if [[ -z "$image_sub_string" ]]; then
    echo "Unsupported Operating System. Aborting."
    exit
  fi
  latest_release=$(
    curl --silent https://api.github.com/repos/firezone/firezone/releases/latest |
    grep '"browser_download_url"' |
    cut -d: -f2,3 |
    sed 's/\"//g' |
    grep $image_sub_string
  )
  eval "$1='$latest_release'"
}

installAndDownloadArtifact() {
  url=$1
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

 main() {
  adminUser=''
  wireguardCheck
  kernelCheck kernelStatus
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance:" adminUser
  if [ "$kernelStatus" != "is supported" ]; then
    echo "$kernelStatus. Quitting."
    exit
  fi

  releaseUrl=''
  mapReleaseToDistro releaseUrl
  echo $releaseUrl
  echo "Press <ENTER> to install Control-C to Abort."
  read
  installAndDownloadArtifact $releaseUrl
  firezone-ctl create-or-reset-admin $adminUser
}

main
