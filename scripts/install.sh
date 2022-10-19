#!/bin/bash
set -e

dockerCheck () {
  if ! type docker > /dev/null; then
    echo 'docker not found. Please install docker and try again.'
    exit
  fi

  if command -v docker-compose &> /dev/null; then
    dc='docker-compose'
  else
    dc='docker compose'
  fi
}

curlCheck () { if ! type curl > /dev/null; then
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
  # Remove trailing slash if present
  externalUrl=$(echo $externalUrl | sed 's:/*$::')
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

promptACME() {
  read -p 'Would you like to enable automatic SSL cert provisioning? Requires a valid DNS record and port 80 to be reachable. (Y/n): ' acme
  case $acme in
    n|N) export CADDY_OPTS="--internal-certs";;
    *)
  esac
}

firezoneSetup() {
  installDir=${installDir/\~/$HOME}
  cd $installDir
  if ! test -f docker-compose.yml; then
    curl -fsSL https://raw.githubusercontent.com/firezone/firezone/master/docker-compose.prod.yml -o docker-compose.yml
  fi
  db_pass=$(od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo)
  docker run --rm firezone/firezone bin/gen-env > .env
  sed -i.bak "s/ADMIN_EMAIL=.*/ADMIN_EMAIL=$1/" .env
  sed -i.bak "s~EXTERNAL_URL=.*~EXTERNAL_URL=$2~" .env
  sed -i.bak "s/DATABASE_PASSWORD=.*/DATABASE_PASSWORD=$db_pass/" .env
  # Set DATABASE_PASSWORD explicitly here in case the user has this var set in their shell
  DATABASE_PASSWORD=$db_pass $dc up -d postgres
  echo 'Waiting for DB to boot...'
  sleep 5
  $dc logs postgres
  echo 'Resetting DB password...'
  $dc exec postgres psql -p 5432 -U postgres -d firezone -h 127.0.0.1 -c "ALTER ROLE postgres WITH PASSWORD '${db_pass}'"
  $dc up -d firezone caddy
  echo 'Waiting for app to boot before creating admin...'
  sleep 15
  $dc exec firezone bin/create-or-reset-admin

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
  defaultExternalUrl="https://$(hostname)"
  adminUser=''
  externalUrl=''
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance: "
  promptInstallDir "Enter the desired installation directory ($defaultInstallDir): "
  promptExternalUrl "Enter the external URL that will be used to access this instance. ($defaultExternalUrl): "
  promptACME
  promptContact
  read -p "Press <ENTER> to install or Ctrl-C to abort."
  firezoneSetup $adminUser $externalUrl
}

dockerCheck
curlCheck

telemetry_id=$(od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo)

capture "install" "email-not-collected@dummy.domain"

main
