#!/bin/bash
set -eE

trap 'handler' ERR

handler () {
  echo
  echo 'An error occurred running this migration. Your existing Firezone installation has not been affected.'
  rm .env
  exit 1
}

curlCheck () {
  if ! type curl > /dev/null; then
    echo 'curl not found. Please install curl to use this script.'
    exit 1
  fi
}

dockerCheck () {
  if ! command -v docker > /dev/null; then
    echo 'docker not found. Please install docker and try again.'
    exit 1
  fi
}

prompt () {
  echo 'This script will copy Omnibus-based Firezone configuration to Docker-based Firezone configuration.'
  echo 'It operates non-destructively and leaves your current Firezone services running.'
  read -p 'Proceed? (Y/n): ' migrate

  case $proceed in
    n|N) echo 'Aborted' ;;
    *) migrate
  esac
}

condIns () {
  dir=$1
  file=$2

  if [ -s "$dir/$file" ]; then
    val=$(cat $dir/$file)
    val=$(echo $val | sed 's/"/\\"/g')
    if [ $file = "EXTERNAL_URL" ]; then
      val=$(echo $val | sed 's:/*$::')
    fi
    echo "$file=\"$val\"" >> .env
  fi
}

migrate () {
  env_files=/opt/firezone/service/phoenix/env
  cwd=`pwd`
  read -p "Enter the desired installation directory ($cwd): " installDir
  if [ -z "$installDir" ]; then
    installDir=$cwd
  fi
  cd $installDir
  if ! test -f docker-compose.yml; then
    curl -fsSL https://raw.githubusercontent.com/firezone/firezone/master/docker-compose.prod.yml -o docker-compose.yml
  fi

  # setup data dir
  mkdir -p /data/firezone/firezone

  # copy tid
  cp $env_files/TELEMETRY_ID /data/firezone/firezone/.tid

  # copy private key
  cp /var/opt/firezone/cache/wg_private_key /data/firezone/firezone/private_key
  chown root:root /data/firezone/firezone/private_key
  chmod 0600 /data/firezone/firezone/private_key

  # generate .env
  if test -f ".env"; then
    echo 'Existing .env detected! Remove and try again.'
    exit 1
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
  echo "DATABASE_HOST=postgres" >> .env
  echo "DATABASE_PORT=5432" >> .env
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
  echo "DATABASE_PASSWORD=\"${db_pass}\"" >> .env
  if test -f $env_files/DEFAULT_ADMIN_PASSWORD; then
    echo "DEFAULT_ADMIN_PASSWORD=\"$(cat $env_files/DEFAULT_ADMIN_PASSWORD)\"" >> .env
  fi
  # END env vars that matter
}

doDumpLoad () {
  if command -v docker-compose &> /dev/null; then
    dc='docker-compose'
  else
    dc='docker compose'
  fi

  echo 'Dumping existing database to ./firezone.sql'
  db_host=$(cat /opt/firezone/service/phoenix/env/DATABASE_HOST)
  db_port=$(cat /opt/firezone/service/phoenix/env/DATABASE_PORT)
  db_name=$(cat /opt/firezone/service/phoenix/env/DATABASE_NAME)
  db_user=$(cat /opt/firezone/service/phoenix/env/DATABASE_USER)
  /opt/firezone/embedded/bin/pg_dump -h $db_host -p $db_port -d $db_name -U $db_user > firezone.sql

  echo 'Loading existing database into docker...'
  DATABASE_PASSWORD=$db_pass $dc up -d postgres
  sleep 5
  $dc exec postgres psql -U postgres -h 127.0.0.1 -c "ALTER ROLE postgres WITH PASSWORD '${db_pass}'"
  $dc exec postgres dropdb -U postgres -h 127.0.0.1 --if-exists $db_name
  $dc exec postgres createdb -U postgres -h 127.0.0.1 $db_name
  $dc exec -T postgres psql -U postgres -h 127.0.0.1 -d $db_name < firezone.sql
  rm firezone.sql
}

dumpLoadDb () {
  echo 'Would you like Firezone to attempt to migrate your existing database to Dockerized Postgres too?'
  echo 'We only recommend this for Firezone installations using the default bundled Postgres.'
  read -p 'Proceed? (Y/n): ' dumpLoad

  case $dumpLoad in
    n|N) echo 'Aborted' ;;
    *) doDumpLoad
  esac
}

doBoot () {
  firezone-ctl stop phoenix
  firezone-ctl stop wireguard
  firezone-ctl stop nginx
  firezone-ctl teardown-network
  $dc up -d
}

printSuccess () {
  echo 'Done! Would you like to stop Omnibus Firezone and start Docker Firezone now?'
  read -p 'Proceed? (y/N): ' boot

  case $boot in
    y|Y) doBoot ;;
    *) echo "Aborted. Run 'firezone-ctl stop && firezone-ctl teardown-network && docker-compose up -d' to stop Omnibus Firezone and start Docker Firezone when you're ready."
  esac
}

curlCheck
dockerCheck
prompt
dumpLoadDb
printSuccess
