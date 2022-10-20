#!/bin/bash
set -eE

trap "handler" ERR

handler () {
  echo
  echo "An error occurred running this migration. Your existing Firezone installation has not been affected."
  echo
  exit 1
}

curlCheck () {
  if ! type curl > /dev/null; then
    echo "curl not found. Please install curl to use this script."
    exit 1
  fi
}

dockerCheck () {
  if ! command -v docker > /dev/null; then
    echo "docker not found. Please install docker and try again."
    exit 1
  fi

  if command -v docker-compose &> /dev/null; then
    dc='docker-compose'
  else
    dc='docker compose'
  fi

  $dc version | grep -q "v2"
  if [ $? -ne 0 ]; then
    echo "Error: Automatic migration is only supported with Docker Compose version 2 or higher."
    exit 1
  fi
}

prompt () {
  echo "This script will copy Omnibus-based Firezone configuration to Docker-based Firezone configuration."
  echo "It operates non-destructively and leaves your current Firezone services running."
  read -p "Proceed? (Y/n): " migrate

  case $proceed in
    n|N)
      echo "Aborted"
      exit
      ;;
    *)
      migrate
      ;;
  esac
}

condIns () {
  dir=$1
  file=$2

  if [ -s "$dir/$file" ]; then
    val=$(cat $dir/$file)
    val=$(echo $val | sed 's/"/\\"/g')
    if [ $file = "EXTERNAL_URL" ]; then
      val=$(echo $val | sed "s:/*$::")
    fi
    echo "$file=\"$val\"" >> $installDir/.env
  fi
}

promptInstallDir() {
  defaultInstallDir="${HOME}/.firezone"
  read -p "Enter the desired installation directory ($defaultInstallDir): " installDir
  if [ -z "$installDir" ]; then
    installDir=$defaultInstallDir
  fi
  if ! test -d $installDir; then
    mkdir $installDir
  fi
}

migrate () {
  export FZ_INSTALL_DIR=$installDir
  promptInstallDir
  env_files=/opt/firezone/service/phoenix/env

  if ! test -f $installDir/docker-compose.yml; then
    curl -fsSL https://raw.githubusercontent.com/firezone/firezone/master/docker-compose.prod.yml -o $installDir/docker-compose.yml
  fi

  # copy tid
  mkdir -p $installDir/firezone/
  cp $env_files/TELEMETRY_ID $installDir/firezone/.tid

  # copy private key
  cp /var/opt/firezone/cache/wg_private_key $installDir/firezone/private_key
  chown $(id -u):$(id -g) $installDir/firezone/private_key
  chmod 0600 $installDir/firezone/private_key

  # generate .env
  if test -f "$installDir/.env"; then
    echo
    echo "Existing .env detected! Moving to .env.bak and continuing..."
    echo
    mv $installDir/.env $installDir/.env.bak
  fi

  # BEGIN env vars that matter
  condIns $env_files "EXTERNAL_URL"
  condIns $env_files "ADMIN_EMAIL"
  condIns $env_files "GUARDIAN_SECRET_KEY"
  condIns $env_files "DATABASE_ENCRYPTION_KEY"
  condIns $env_files "SECRET_KEY_BASE"
  condIns $env_files "LIVE_VIEW_SIGNING_SALT"
  condIns $env_files "COOKIE_SIGNING_SALT"
  condIns $env_files "COOKIE_ENCRYPTION_SALT"
  condIns $env_files "DATABASE_NAME"
  # These shouldn't change
  echo "DATABASE_HOST=postgres" >> $installDir/.env
  echo "DATABASE_PORT=5432" >> $installDir/.env
  condIns $env_files "DATABASE_POOL"
  condIns $env_files "DATABASE_SSL"
  condIns $env_files "DATABASE_SSL_OPTS"
  condIns $env_files "DATABASE_PARAMETERS"
  condIns $env_files "EXTERNAL_TRUSTED_PROXIES"
  condIns $env_files "PRIVATE_CLIENTS"
  condIns $env_files "WIREGUARD_PORT"
  condIns $env_files "WIREGUARD_DNS"
  condIns $env_files "WIREGUARD_ALLOWED_IPS"
  condIns $env_files "WIREGUARD_PERSISTENT_KEEPALIVE"
  condIns $env_files "WIREGUARD_MTU"
  condIns $env_files "WIREGUARD_ENDPOINT"
  condIns $env_files "WIREGUARD_IPV4_ENABLED"
  condIns $env_files "WIREGUARD_IPV4_MASQUERADE"
  condIns $env_files "WIREGUARD_IPV4_NETWORK"
  condIns $env_files "WIREGUARD_IPV4_ADDRESS"
  condIns $env_files "WIREGUARD_IPV6_ENABLED"
  condIns $env_files "WIREGUARD_IPV6_MASQUERADE"
  condIns $env_files "WIREGUARD_IPV6_NETWORK"
  condIns $env_files "WIREGUARD_IPV6_ADDRESS"
  condIns $env_files "DISABLE_VPN_ON_OIDC_ERROR"
  condIns $env_files "SECURE_COOKIES"
  condIns $env_files "ALLOW_UNPRIVILEGED_DEVICE_MANAGEMENT"
  condIns $env_files "ALLOW_UNPRIVILEGED_DEVICE_CONFIGURATION"
  condIns $env_files "OUTBOUND_EMAIL_FROM"
  condIns $env_files "OUTBOUND_EMAIL_PROVIDER"
  condIns $env_files "OUTBOUND_EMAIL_CONFIGS"
  condIns $env_files "AUTH_OIDC_JSON"
  condIns $env_files "LOCAL_AUTH_ENABLED"
  condIns $env_files "MAX_DEVICES_PER_USER"
  condIns $env_files "CONNECTIVITY_CHECKS_ENABLED"
  condIns $env_files "CONNECTIVITY_CHECKS_INTERVAL"

  # optional vars
  if test -f $env_files/DATABASE_PASSWORD; then
    db_pass=$(cat $env_files/DATABASE_PASSWORD)
  else
    db_pass=$(/opt/firezone/embedded/bin/openssl rand -base64 12)
  fi
  echo "DATABASE_PASSWORD=\"${db_pass}\"" >> $installDir/.env
  if test -f $env_files/DEFAULT_ADMIN_PASSWORD; then
    echo "DEFAULT_ADMIN_PASSWORD=\"$(cat $env_files/DEFAULT_ADMIN_PASSWORD)\"" >> $installDir/.env
  fi
  # END env vars that matter
}

doDumpLoad () {
  echo "Dumping existing database to $installDir/firezone_omnibus_backup.sql"
  db_host=$(cat /opt/firezone/service/phoenix/env/DATABASE_HOST)
  db_port=$(cat /opt/firezone/service/phoenix/env/DATABASE_PORT)
  db_name=$(cat /opt/firezone/service/phoenix/env/DATABASE_NAME)
  db_user=$(cat /opt/firezone/service/phoenix/env/DATABASE_USER)
  /opt/firezone/embedded/bin/pg_dump -h $db_host -p $db_port -d $db_name -U $db_user > $installDir/firezone_omnibus_backup.sql

  echo "Loading existing database into docker..."
  DATABASE_PASSWORD=$db_pass $dc -f $installDir/docker-compose.yml up -d postgres
  sleep 5
  $dc -f $installDir/docker-compose.yml exec postgres psql -U postgres -h 127.0.0.1 -c "ALTER ROLE postgres WITH PASSWORD '${db_pass}'"
  $dc -f $installDir/docker-compose.yml exec postgres dropdb -U postgres -h 127.0.0.1 --if-exists $db_name
  $dc -f $installDir/docker-compose.yml exec postgres createdb -U postgres -h 127.0.0.1 $db_name
  $dc -f $installDir/docker-compose.yml exec -T postgres psql -U postgres -h 127.0.0.1 -d $db_name < $installDir/firezone_omnibus_backup.sql
  rm $installDir/firezone_omnibus_backup.sql
}

dumpLoadDb () {
  echo "Would you like Firezone to attempt to migrate your existing database to Dockerized Postgres too?"
  echo "We only recommend this for Firezone installations using the default bundled Postgres."
  read -p "Proceed? (Y/n): " dumpLoad

  case $dumpLoad in
    n|N)
      echo "Aborted"
      exit
      ;;
    *)
      doDumpLoad
      ;;
  esac
}

doBoot () {
  echo "Stopping Omnibus Firezone..."
  firezone-ctl stop

  echo "Tearing down network..."
  firezone-ctl teardown-network

  echo "Disabling systemd unit..."
  systemctl disable firezone-runsvdir-start.service

  echo "Bringing Docker services up..."
  $dc -f $installDir/docker-compose.yml up -d
}

printSuccess () {
  echo "Done! Would you like to stop Omnibus Firezone and start Docker Firezone now?"
  read -p "Proceed? (y/N): " boot

  case $boot in
    y|Y)
      doBoot
      ;;
    *)
cat << EOF
Aborted. Run the following to stop Omnibus Firezone and start Docker Firezone when you're ready.

  sudo firezone-ctl stop
  sudo firezone-ctl teardown-network
  docker-compose up -d

You may also want to disable the systemd unit:

  sudo systemctl disable firezone-runsvdir-start.service

EOF
    exit
    ;;
  esac
}

curlCheck
dockerCheck
prompt
dumpLoadDb
printSuccess
