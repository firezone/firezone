Name:       firezone
Version:    0.2.0
Release:    1
Summary:    Web UI + Firewall manager for WireGuard™
URL:        https://firez.one
License:    ASL 2.0
Requires:   net-tools
Requires:   wireguard-tools
Requires:   postgresql-server
Requires:   openssl
Requires:   systemd
Requires:   iptables
Requires:   glibc

%description
Provides a web-based UI that allows you to configure WireGuard™ VPN tunnels and
set up firewall rules for your devices.

%post
# FireZone package post-install script

# All created files are 0600 by default
umask 077

# Add firezone user if not exists
if id firezone &>/dev/null; then
  echo "firezone user exists... not creating."
else
  echo "creating system user firezone"
  useradd --system firezone
fi

hostname=$(hostname)

### SET UP DB

# Create role if not exists
db_user=firezone
db_password="$(openssl rand -hex 16)"
res=$(su postgres -c "psql -c \"SELECT 1 FROM pg_roles WHERE rolname = '${db_user}';\"")
if [[ $res == *"0 rows"* ]]; then
  su postgres -c "psql -c \"CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}';\""
else
  echo "${db_user} role found in DB"
fi

# Create DB if not exists
db_name=firezone
res=$(su postgres -c "psql -c \"SELECT 1 FROM pg_database WHERE datname = '${db_name}';\"")
if [[ $res == *"0 rows"* ]]; then
  su postgres -c "psql -c \"CREATE DATABASE firezone;\" || true"
else
  echo "${db_name} exists; not creating"
fi

# Grant all privileges
su postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE firezone to ${db_user};\""

# Set up secrets dir
mkdir -p /etc/firezone/secret
chown firezone:root /etc/firezone/secret
chmod 770 /etc/firezone/secret

# Write FireZone SSL files
ssl_key_file=/etc/firezone/secret/key.pem
ssl_cert_file=/etc/firezone/cert.pem
if [ -f $ssl_key_file ] && [ -f $ssl_cert_file ]; then
  echo "ssl files exist; not creating"
else
  openssl req -new -x509 -sha256 -newkey rsa:2048 -nodes \
      -keyout $ssl_key_file \
      -out $ssl_cert_file \
      -days 365 -subj "/CN=${hostname}"
fi

# Generate app secrets
live_view_signing_salt="$(openssl rand -base64 24)"
secret_key_base="$(openssl rand -base64 48)"
db_key="$(openssl rand -base64 32)"
wg_server_key="$(wg genkey)"

# Write FireZone config file
if [ -f /etc/firezone/secret/secrets.env ]; then
  echo "config file exists; not creating"
else

umask 037
cat <<EOT > /etc/firezone/secret/secrets.env
# This file is loaded into FireZone's Environment upon launch to configure it.

# Warning: changing anything here can result in data loss. Make sure you know
# what you're doing!

# This is used to ensure secure communication with the live web views.
# Re-generate this with "openssl rand -base64 24". All existing web views will
# need to be refreshed.
LIVE_VIEW_SIGNING_SALT="${live_view_signing_salt}"

# This is used to secure cookies among other things.
# You can regenerate this with "openssl rand -base64 48". All existing clients
# will be signed out.
SECRET_KEY_BASE="${secret_key_base}"

# The URL to connect to your DB. Assumes the database has been created and this
# user has privileges to create and modify tables. Must start with ecto://
# Ex: ecto://user:password@localhost/firezone
DATABASE_URL="ecto://${db_user}:${db_password}@127.0.0.1/firezone"

# The Base64-encoded key for encrypted database fields.
DB_ENCRYPTION_KEY=${db_key}

# The Base64-encoded private key for the WireGuard interface
WG_SERVER_KEY=${wg_server_key}
EOT
fi

# Set perms
chown -R firezone:root /etc/firezone
chmod 0644 /etc/firezone/cert.pem





%postun
echo "Refusing to purge /etc/firezone/secret and drop database. This must be done manually."
echo "If you really want to do this, run the following as root:"
echo "  su postgres -c 'psql -c \"DROP DATABASE firezone;\"'"
echo "  rm -rf /etc/firezone/secret"

%files
%config /etc/firezone
%attr(0644, root, root) /usr/lib/systemd/system/firezone.service
/usr/lib/firezone
