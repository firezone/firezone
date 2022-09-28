#!/bin/bash
set -e

osCheck () {
  os=`uname -s`
  if [ ! $os = "Linux" ]; then
    echo "Please ensure you're running this script on Linux and try again."
    exit
  fi
}

dockerCheck () {
  if ! type docker > /dev/null; then
    echo 'docker not found. Please install docker and try again.'
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
        -m 5 \
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

promptInstallDir() {
  read -p "$1" installDir
  if [ -z "$installDir" ]; then
    installDir=$defaultInstallDir
  fi
}

promptExternalUrl() {
  read -p "$1" externalUrl
  if [ -z "$externalUrl" ]; then
    externalUrl=$defaultExternalUrl
  fi
}

promptEmail() {
  read -p "$1" adminEmail
  case $adminEmail in
    *@*) adminUser=$adminEmail;;
    *) promptEmail "Please provide a valid email: "
  esac
}

promptContact() {
  read -p 'Could we email you to ask for product feedback? Firezone depends heavily on input from users like you to steer development. (Y/n): ' contact
  case $contact in
    n|N);;
    *) capture "contactOk" $adminUser
  esac
}

wireguardCheck() {
  if ! test -f /sys/module/wireguard/version; then
    if test -d /lib/modules/$(uname -r) && test -f `find /lib/modules/$(uname -r) -type f -name 'wireguard.ko'`; then
      echo "WireGuard kernel module found, but not loaded. Load it now? (Y/n): "
      read load_wgmod
      case $load_wgmod in
        n|N) echo "Load it with 'sudo modprobe wireguard' and run this install script again"; exit;;
        *) modprobe wireguard
      esac
    else
      echo "Error! WireGuard not detected. Please upgrade your kernel to at least 5.6 or install the WireGuard kernel module."
      echo "See more at https://www.wireguard.com/install/"
      exit
    fi
  fi
}

kernelCheck() {
  major=`uname -r | cut -d'.' -f1`
  if [ "$major" -lt "5" ]; then
    echo "Kernel version `uname -r ` is not supported. Please upgrade to 5.0 or higher."
    exit
  fi
}

firezoneSetup() {
  cd $installDir
  curl -fsSL https://raw.githubusercontent.com/firezone/firezone/master/docker-compose.prod.yml -o docker-compose.yml
  docker run --rm firezone/firezone bin/gen-env > .env
  sed -i "s/ADMIN_EMAIL=_CHANGE_ME_/ADMIN_EMAIL=$1/" .env
  sed -i "s~EXTERNAL_URL=_CHANGE_ME_~EXTERNAL_URL=$2~" .env
  sed -i "s/TELEMETRY_ID=.*/TELEMETRY_ID=$telemetry_id/" .env
  docker-compose up -d
  docker compose run --rm firezone bin/create-or-reset-admin

  displayLogo

cat << EOF
Installation complete!

You should now be able to log into the Web UI at $externalUrl with the
following credentials:

`grep ADMIN_EMAIL .env`
`grep DEFAULT_ADMIN_PASSWORD .env`

EOF

  cd -
}

displayLogo() {
cat << EOF






                                             ::
                                              !!:
                                              .??^
                                               ~J?^
                                               :???.
                                               .??J^
                                               .??J!
                                               .??J!
                                               ^J?J~
                                               !???:
                                              .???? ::
                                              ^J?J! :~:
                                              7???: :~~
                                             .???7  ~~~.
                                             :??J^ :~~^
                                             :???..~~~:
           .............                     .?J7 ^~~~        ....
        ..        ......::....                ~J!.~~~^       ::..
                         ...:::....            !7^~~~^     .^: .
                             ...:::....         ~~~~~~:. .:~^ .
                                ....:::....      .~~~~~~~~~:..
                                    ...::::....   .::^^^^:...
                                       .....:::.............
                                           .......:::.....








EOF
}


main() {
  defaultInstallDir=`pwd`
  defaultExternalUrl="https://$public_ip/"
  adminUser=''
  externalUrl=''
  kernelCheck
  wireguardCheck
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance: "
  promptInstallDir "Enter the desired installation directory ($defaultInstallDir): "
  promptExternalUrl "Enter the external URL that will be used to access this instance ($defaultExternalUrl): "
  promptContact
  read -p "Press <ENTER> to install or Ctrl-C to abort."
  firezoneSetup $adminUser $externalUrl
}

osCheck
dockerCheck
curlCheck

telemetry_id=`od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo`
public_ip=`curl -m 5 --silent ifconfig.me`

capture "install" "email-not-collected@dummy.domain"

main
