#!/bin/bash
set -e

dockerCheck () {
  if ! type docker > /dev/null; then
    echo "docker not found. Please install docker and try again."
    exit 1
  fi

  if command docker compose &> /dev/null; then
    dc="docker compose"
  else
    if command -v docker-compose &> /dev/null; then
      dc="docker-compose"
    else
      echo "Error: Docker Compose not found. Please install Docker Compose version 2 or higher."
      exit 1
    fi
  fi

  set +e
  $dc version | grep -q "v2"
  if [ $? -ne 0 ]; then
    echo "Error: Automatic installation is only supported with Docker Compose version 2 or higher."
    echo "Please upgrade Docker Compose or use the manual installation method: https://docs.firezone.dev/deploy/docker"
    exit 1
  fi
  set -e
}

curlCheck () {
  if ! type curl > /dev/null; then
    echo "curl not found. Please install curl to use this script."
    exit 1
  fi
}

capture () {
  if type curl > /dev/null; then
    if [ ! -z "$tid" ]; then
      curl -s -XPOST \
        -m 5 \
        -H "Content-Type: application/json" \
        -d "{
          \"api_key\": \"phc_xnIRwzHSaI6c81ukilv09w2TRWUJIRo4VCxshvl7znY\",
          \"event\": \"$1\",
          \"properties\": {
            \"distinct_id\": \"$tid\",
            \"email\": \"$2\"
          }
        }" \
        https://t.firez.one/capture/ > /dev/null \
        || true
    fi
  fi
}

promptInstallDir() {
  read -p "$1" installDir
  if [ -z "$installDir" ]; then
    installDir=$defaultInstallDir
  fi
  if ! test -d $installDir; then
    mkdir $installDir
  fi
}

promptExternalUrl() {
  read -p "$1" externalUrl
  # Remove trailing slash if present
  externalUrl=$(echo $externalUrl | sed "s:/*$::")
  if [ -z "$externalUrl" ]; then
    externalUrl=$defaultExternalUrl
  fi
}

promptEmail() {
  read -p "$1" adminEmail
  case $adminEmail in
    *@*)
      adminUser=$adminEmail
      ;;
    *)
      promptEmail "Please provide a valid email: "
      ;;
  esac
}

promptContact() {
  read -p "Could we email you to ask for product feedback? Firezone depends heavily on input from users like you to steer development. (Y/n): " contact
  case $contact in
    n|N)
      ;;
    *)
      capture "contactOk" $adminUser
      ;;
  esac
}

promptACME() {
  read -p "Would you like to enable automatic SSL cert provisioning? Requires a valid DNS record and port 80 to be reachable. (Y/n): " acme
  case $acme in
    n|N)
      tlsOpts="tls internal {
                on_demand
              }"
      ;;
    *)
      tlsOpts="tls {
                on_demand
              }"
      ;;
  esac
}

promptTelemetry() {
  read -p "Firezone collects crash and performance logs to help us improve the product. Would you like to disable this? (N/y): " telem
  case $telem in
    y|Y)
      telemEnabled="false"
      ;;
    *)
      telemEnabled="true"
      ;;
  esac
}

firezoneSetup() {
  export FZ_INSTALL_DIR=$installDir

  if ! test -f $installDir/docker-compose.yml; then
    os_type="$(uname -s)"
    case "${os_type}" in
      Linux*)
        file=docker-compose.prod.yml
        ;;
      *)
        file=docker-compose.desktop.yml
        ;;
    esac
    curl -fsSL https://raw.githubusercontent.com/firezone/firezone/master/$file -o $installDir/docker-compose.yml
  fi
  db_pass=$(od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo)
  docker run --rm firezone/firezone bin/gen-env > "$installDir/.env"
  sed -i.bak "s/ADMIN_EMAIL=.*/ADMIN_EMAIL=$1/" "$installDir/.env"
  sed -i.bak "s~EXTERNAL_URL=.*~EXTERNAL_URL=$2~" "$installDir/.env"
  sed -i.bak "s/DATABASE_PASSWORD=.*/DATABASE_PASSWORD=$db_pass/" "$installDir/.env"
  echo "TLS_OPTS=\"$3\"" >> "$installDir/.env"
  echo "TELEMETRY_ENABLED=$telemEnabled" >> "$installDir/.env"
  echo "TID=$tid" >> "$installDir/.env"

  # XXX: This causes perms issues on macOS with postgres
  # echo "UID=$(id -u)" >> $installDir/.env
  # echo "GID=$(id -g)" >> $installDir/.env

  # Set DATABASE_PASSWORD explicitly here in case the user has this var set in their shell
  DATABASE_PASSWORD=$db_pass $dc -f $installDir/docker-compose.yml up -d postgres
  echo "Waiting for DB to boot..."
  sleep 5
  $dc -f $installDir/docker-compose.yml logs postgres
  echo "Resetting DB password..."
  $dc -f $installDir/docker-compose.yml exec postgres psql -p 5432 -U postgres -d firezone -h 127.0.0.1 -c "ALTER ROLE postgres WITH PASSWORD '${db_pass}'"
  echo "Migrating DB..."
  $dc -f $installDir/docker-compose.yml run -e TELEMETRY_ID="${tid}" --rm firezone bin/migrate
  echo "Creating admin..."
  $dc -f $installDir/docker-compose.yml run -e TELEMETRY_ID="${tid}" --rm firezone bin/create-or-reset-admin
  echo "Upping firezone services..."
  $dc -f $installDir/docker-compose.yml up -d firezone caddy

  displayLogo

cat << EOF
Installation complete!

You should now be able to log into the Web UI at $externalUrl with the
following credentials:

`grep ADMIN_EMAIL $installDir/.env`
`grep DEFAULT_ADMIN_PASSWORD $installDir/.env`

EOF
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
  defaultExternalUrl="https://$(hostname)"
  adminUser=""
  externalUrl=""
  defaultInstallDir="$HOME/.firezone"
  tlsOpts=""
  promptEmail "Enter the administrator email you'd like to use for logging into this Firezone instance: "
  promptInstallDir "Enter the desired installation directory ($defaultInstallDir): "
  promptExternalUrl "Enter the external URL that will be used to access this instance. ($defaultExternalUrl): "
  promptACME
  promptContact
  promptTelemetry
  read -p "Press <ENTER> to install or Ctrl-C to abort."
  if [ $telemEnabled = "true" ]; then
    capture "install" "email-not-collected@dummy.domain"
  fi
  firezoneSetup $adminUser $externalUrl "$tlsOpts"
}

dockerCheck
curlCheck

telemetry_id=$(od -vN "8" -An -tx1 /dev/urandom | tr -d " \n" ; echo)
tid=${1:-$telemetry_id}

main
