# frozen_string_literal: true

# # Firezone configuration

require 'etc'

#
# Attributes here will be applied to configure the application and the services
# it uses.
#
# Most of the attributes in this file are things you will not need to ever
# touch, but they are here in case you need them.
#
# A `firezone-ctl reconfigure` should pick up any changes made here.
#
# If /etc/firezone/firezone.json exists, its attributes will be loaded
# after these, so if you have that file with the contents:
#
#     { "postgresql": { "enable": false } }
#
# for example, it will set the node['firezone']['postgresql']['enabled'] attribute to false.

# ## Top-level attributes
#
# These are used by the other items below. More app-specific top-level
# attributes are further down in this file.

# ## External URL (REQUIRED)
#
# This will be used to generate URLs for outbound emails, websocket connections
# and OAuth redirects.
# and host headers that nginx passes along. If using a custom path, scheme, or port,
# you may want to change this, e.g. http://firezone.example.com:1234/custom-root-prefix/
default['firezone']['external_url'] = "https://#{node['fqdn'] || node['hostname']}"

# Email for the primary admin user.
default['firezone']['admin_email'] = 'firezone@localhost'

# The maximum number of devices a user can have.
# Max: 100
# Default: 10
default['firezone']['max_devices_per_user'] = 10

# Allow users to create (and download) their own devices. Set to false
# if you only want administrators to create and manage devices.
default['firezone']['allow_unprivileged_device_management'] = true

default['firezone']['config_directory'] = '/etc/firezone'
default['firezone']['install_directory'] = '/opt/firezone'
default['firezone']['app_directory'] = "#{node['firezone']['install_directory']}/embedded/service/firezone"
default['firezone']['log_directory'] = '/var/log/firezone'
default['firezone']['var_directory'] = '/var/opt/firezone'
default['firezone']['user'] = 'firezone'
default['firezone']['group'] = 'firezone'

# The outgoing interface name.
# This is where tunneled traffic will exit the WireGuard tunnel.
# If set to nil, this is will be set to the interface for the machine's
# default route.
default['firezone']['egress_interface'] = nil

# Whether to use OpenSSL FIPS mode across Firezone. Default disabled.
default['firezone']['fips_enabled'] = nil

# ## Global Logging Settings
#
# Enable or disable logging. Set this to false to disable Firezone logs.
default['firezone']['logging']['enabled'] = true

# ## Enterprise
#
# The "enterprise" cookbook provides recipes and resources we can use for this
# app.

default['enterprise']['name'] = 'firezone'

# Enterprise uses install_path internally, but we use install_directory because
# it's more consistent. Alias it here so both work.
default['firezone']['install_path'] = node['firezone']['install_directory']

# An identifier used in /etc/inittab (default is 'SUP'). Needs to be a unique
# (for the file) sequence of 1-4 characters.
default['firezone']['sysvinit_id'] = 'SUP'

# ## Authentication

# These settings control authentication-related aspects of Firezone.
# For more information, see https://docs.firezone.dev/docs/user-guides/authentication/
#
# When local email/password authentication is used, users must be created by an Administrator
# before they can sign in.
#
# When SSO authentication methods are used, users are automatically added to Firezone
# when logging in for the first time via the SSO provider.
#
# Users are uniquely identified by their email address, and may sign in via multiple providers
# if configured.

# Local email/password authentication is enabled by default
default['firezone']['authentication']['local']['enabled'] = true

# OIDC Authentication
# Any OpenID Connect provider can be used here.
# Example of a Google setup
default['firezone']['authentication']['oidc']['google'] = {
    discovery_document_uri: "https://accounts.google.com/.well-known/openid-configuration",
    client_id: "CLIENT_ID",
    client_secret: "CLIENT_SECRET",
    redirect_uri: "https://example.com/session",
    response_type: "code",
    scope: "openid email profile",
    label: "Google"
}

# DEPRECATED
# Previously, Firezone used preconfigured Oauth2 providers. We've moved to OIDC authentication
# which allows for any OpenID Connect provider (Google, Okta, Dex) to be used for authetication.
# See the above OIDC Authentication section
#
# DEPRECATED: Okta example config
default['firezone']['authentication']['okta']['enabled'] = false
default['firezone']['authentication']['okta']['client_id'] = nil
default['firezone']['authentication']['okta']['client_secret'] = nil
default['firezone']['authentication']['okta']['site'] = 'https://your-domain.okta.com'

# DEPRECATED: Google example config
default['firezone']['authentication']['google']['enabled'] = false
default['firezone']['authentication']['google']['client_id'] = nil
default['firezone']['authentication']['google']['client_secret'] = nil
default['firezone']['authentication']['google']['redirect_uri'] = nil

# ## Nginx

# These attributes control Firezone-specific portions of the Nginx
# configuration and the virtual host for the Firezone Phoenix app.
default['firezone']['nginx']['enabled'] = true
default['firezone']['nginx']['force_ssl'] = true
default['firezone']['nginx']['non_ssl_port'] = 80
default['firezone']['nginx']['ssl_port'] = 443
default['firezone']['nginx']['directory'] = "#{node['firezone']['var_directory']}/nginx/etc"
default['firezone']['nginx']['log_directory'] = "#{node['firezone']['log_directory']}/nginx"
default['firezone']['nginx']['log_rotation']['file_maxbytes'] = 104_857_600
default['firezone']['nginx']['log_rotation']['num_to_keep'] = 10
default['firezone']['nginx']['log_x_forwarded_for'] = false

# Redirect to the FQDN
default['firezone']['nginx']['redirect_to_canonical'] = false

# Controls nginx caching, used to cache some endpoints
default['firezone']['nginx']['cache']['enabled'] = false
default['firezone']['nginx']['cache']['directory'] = "#{node['firezone']['var_directory']}/nginx/cache"

# These attributes control the main nginx.conf, including the events and http
# contexts.
#
# These will be copied to the top-level nginx namespace and used in a
# template from the community nginx cookbook
# (https://github.com/miketheman/nginx/blob/master/templates/default/nginx.conf.erb)
default['firezone']['nginx']['user'] = node['firezone']['user']
default['firezone']['nginx']['group'] = node['firezone']['group']
default['firezone']['nginx']['dir'] = node['firezone']['nginx']['directory']
default['firezone']['nginx']['log_dir'] = node['firezone']['nginx']['log_directory']
default['firezone']['nginx']['pid'] = "#{node['firezone']['nginx']['directory']}/nginx.pid"
default['firezone']['nginx']['daemon_disable'] = true
default['firezone']['nginx']['gzip'] = 'on'
default['firezone']['nginx']['gzip_static'] = 'off'
default['firezone']['nginx']['gzip_http_version'] = '1.0'
default['firezone']['nginx']['gzip_comp_level'] = '2'
default['firezone']['nginx']['gzip_proxied'] = 'any'
default['firezone']['nginx']['gzip_vary'] = 'off'
default['firezone']['nginx']['gzip_buffers'] = nil
default['firezone']['nginx']['gzip_types'] = %w[
  text/plain
  text/css
  application/x-javascript
  text/xml
  application/xml
  application/rss+xml
  application/atom+xml
  text/javascript
  application/javascript
  application/json
]
default['firezone']['nginx']['gzip_min_length'] = 1000
default['firezone']['nginx']['gzip_disable'] = 'MSIE [1-6]\.'
default['firezone']['nginx']['keepalive'] = 'on'
default['firezone']['nginx']['keepalive_timeout'] = 65
default['firezone']['nginx']['worker_processes'] = node['cpu'] && node['cpu']['total'] ? node['cpu']['total'] : 1
default['firezone']['nginx']['worker_connections'] = 1024
default['firezone']['nginx']['worker_rlimit_nofile'] = nil
default['firezone']['nginx']['multi_accept'] = true
default['firezone']['nginx']['event'] = 'epoll'
default['firezone']['nginx']['server_tokens'] = nil
default['firezone']['nginx']['server_names_hash_bucket_size'] = 64
default['firezone']['nginx']['sendfile'] = 'on'
default['firezone']['nginx']['access_log_options'] = nil
default['firezone']['nginx']['error_log_options'] = nil
default['firezone']['nginx']['disable_access_log'] = false
default['firezone']['nginx']['types_hash_max_size'] = 2048
default['firezone']['nginx']['types_hash_bucket_size'] = 64
default['firezone']['nginx']['proxy_read_timeout'] = nil
default['firezone']['nginx']['client_body_buffer_size'] = nil
default['firezone']['nginx']['client_max_body_size'] = '250m'
default['firezone']['nginx']['default']['modules'] = []

# Nginx rate limiting configuration.
# Note that requests are also rate limited by the upstream Phoenix application.
default['firezone']['nginx']['enable_rate_limiting'] = true
default['firezone']['nginx']['rate_limiting_zone_name'] = 'firezone'
default['firezone']['nginx']['rate_limiting_backoff'] = '10m'
default['firezone']['nginx']['rate_limit'] = '10r/s'

# ## Postgres

# ### Use the bundled Postgres instance (default, recommended):
#

default['firezone']['postgresql']['enabled'] = true
default['firezone']['postgresql']['username'] = node['firezone']['user']
default['firezone']['postgresql']['data_directory'] = "#{node['firezone']['var_directory']}/postgresql/13.3/data"

# ### Using an external Postgres database
#
# Disable the provided Postgres instance and connect to your own:
#
# default['firezone']['postgresql']['enabled'] = false
# default['firezone']['database']['user'] = 'my_db_user_name'
# default['firezone']['database']['name'] = 'my_db_name''
# default['firezone']['database']['host'] = 'my.db.server.address'
# default['firezone']['database']['port'] = 5432
#
# Further database configuration options can be found below

# ### Logs
default['firezone']['postgresql']['log_directory'] = "#{node['firezone']['log_directory']}/postgresql"
default['firezone']['postgresql']['log_rotation']['file_maxbytes'] = 104_857_600
default['firezone']['postgresql']['log_rotation']['num_to_keep'] = 10

# ### Postgres Settings
default['firezone']['postgresql']['checkpoint_completion_target'] = 0.5
default['firezone']['postgresql']['checkpoint_segments'] = 3
default['firezone']['postgresql']['checkpoint_timeout'] = '5min'
default['firezone']['postgresql']['checkpoint_warning'] = '30s'
default['firezone']['postgresql']['effective_cache_size'] = '128MB'
default['firezone']['postgresql']['listen_address'] = '127.0.0.1'
default['firezone']['postgresql']['max_connections'] = 350
default['firezone']['postgresql']['md5_auth_cidr_addresses'] = ['127.0.0.1/32', '::1/128']
default['firezone']['postgresql']['port'] = 15_432
default['firezone']['postgresql']['shared_buffers'] = "#{(node['memory']['total'].to_i / 4) / 1024}MB"
default['firezone']['postgresql']['shmmax'] = 17_179_869_184
default['firezone']['postgresql']['shmall'] = 4_194_304
default['firezone']['postgresql']['work_mem'] = '8MB'

# ## Common Database Settings
#
# The settings below configure how Firezone connects to and uses your database.
# At this time only Postgres (and Postgres-compatible) databases are supported.
default['firezone']['database']['user'] = node['firezone']['postgresql']['username']
default['firezone']['database']['name'] = 'firezone'
default['firezone']['database']['host'] = node['firezone']['postgresql']['listen_address']
default['firezone']['database']['port'] = node['firezone']['postgresql']['port']
default['firezone']['database']['ssl'] = false
default['firezone']['database']['ssl_opts'] = {}
default['firezone']['database']['parameters'] = {}
default['firezone']['database']['pool'] = [10, Etc.nprocessors].max
default['firezone']['database']['extensions'] = { 'plpgsql' => true, 'pg_trgm' => true }

# Create the DB user. Set this to false if the user already exists.
default['firezone']['database']['create_user'] = true

# Create the DB. Set this to false if the database already exists.
default['firezone']['database']['create_db'] = true

# Uncomment to specify a database password. Not usually needed if using the bundled Postgresql.
# default['firezone']['database']['password'] = 'change_me'

# ## Phoenix

# ### The Phoenix web app for Firezone
default['firezone']['phoenix']['enabled'] = true
default['firezone']['phoenix']['port'] = 13_000
default['firezone']['phoenix']['log_directory'] = "#{node['firezone']['log_directory']}/phoenix"
default['firezone']['phoenix']['log_rotation']['file_maxbytes'] = 104_857_600
default['firezone']['phoenix']['log_rotation']['num_to_keep'] = 10

# ## WireGuard

# ### Interface Management
# Enable management of the WireGuard interface itself. Set this to false if you
# want to manually create your WireGuard interface and manage its interface properties.
default['firezone']['wireguard']['enabled'] = true
default['firezone']['wireguard']['log_directory'] = "#{node['firezone']['log_directory']}/wireguard"
default['firezone']['wireguard']['log_rotation']['file_maxbytes'] = 104_857_600
default['firezone']['wireguard']['log_rotation']['num_to_keep'] = 10

# The WireGuard interface name Firezone will apply configuration settings to.
default['firezone']['wireguard']['interface_name'] = 'wg-firezone'

# WireGuard listen port
default['firezone']['wireguard']['port'] = 51_820

# WireGuard interface MTU
default['firezone']['wireguard']['mtu'] = 1420

# WireGuard endpoint
# By default, the public IP address of this server is used as the Endpoint
# field for generating Device configs. Override this if you wish to change.
default['firezone']['wireguard']['endpoint'] = nil

# Default AllowedIPs to use for generated device configs specified as a comma-separated
# list of IPv4 / IPv6 CIDRs.
# Default is to tunnel all IPv4 and IPv6 traffic with '0.0.0.0/0, ::/0'
default['firezone']['wireguard']['allowed_ips'] = '0.0.0.0/0, ::/0'

# Default DNS servers to use for generated device configs.
# Defaults to CloudFlare's public DNS. Set to nil to omit DNS from generated
# device configurations.
default['firezone']['wireguard']['dns'] = '1.1.1.1, 1.0.0.1'

# Default PersistentKeepalive setting to use for generated device configs.
# See https://www.wireguard.com/quickstart/#nat-and-firewall-traversal-persistence
# Set to 0 or nil to disable. Default 0.
default['firezone']['wireguard']['persistent_keepalive'] = 0

# Enable or disable IPv4 connectivity in your WireGuard network. Default enabled.
default['firezone']['wireguard']['ipv4']['enabled'] = true

# The CIDR-formatted IPv4 network to use for your WireGuard network. Default 10.3.2.0/24.
default['firezone']['wireguard']['ipv4']['network'] = '10.3.2.0/24'

# The IPv4 address to assign to your WireGuard interface. Must be an address
# contained within the WireGuard network specific above. Default 10.3.2.1.
default['firezone']['wireguard']['ipv4']['address'] = '10.3.2.1'

# Enable or disable IPv6 connectivity in your WireGuard network. Default enabled.
default['firezone']['wireguard']['ipv6']['enabled'] = true

# The CIDR-formatted IPv6 network to use for your WireGuard network. Default fd00::3:2:0/120.
default['firezone']['wireguard']['ipv6']['network'] = 'fd00::3:2:0/120'

# The IPv6 address to assign to your WireGuard interface. Must be an address
# contained within the WireGuard network specific above. Default fd00::3:2:1.
default['firezone']['wireguard']['ipv6']['address'] = 'fd00::3:2:1'

# ## Runit

# This is missing from the enterprise cookbook
# see (https://github.com/chef-cookbooks/enterprise-chef-common/pull/17)
#
# Will be copied to the root node.runit namespace.
default['firezone']['runit']['svlogd_bin'] = "#{node['firezone']['install_directory']}/embedded/bin/svlogd"

# ## SSL

default['firezone']['ssl']['directory'] = '/var/opt/firezone/ssl'

# Enable / disable SSL
default['firezone']['ssl']['enabled'] = true

# Paths to the SSL certificate and key files. If these are not provided we will
# attempt to generate a self-signed certificate and use that instead.
default['firezone']['ssl']['certificate'] = nil
default['firezone']['ssl']['certificate_key'] = nil

# Path to the SSL dhparam file if you want to specify your own SSL DH parameters.
default['firezone']['ssl']['ssl_dhparam'] = nil

# These are used in creating a self-signed cert if you haven't brought your own.
default['firezone']['ssl']['country_name'] = 'US'
default['firezone']['ssl']['state_name'] = 'CA'
default['firezone']['ssl']['locality_name'] = 'San Francisco'
default['firezone']['ssl']['company_name'] = 'My Company'
default['firezone']['ssl']['organizational_unit_name'] = 'Operations'
default['firezone']['ssl']['email_address'] = 'you@example.com'

# ### Cipher settings
#
# Based off of the Mozilla recommended cipher suite
# https://wiki.mozilla.org/Security/Server_Side_TLS#Recommended_Ciphersuite
#
# SSLV3 was removed because of the poodle attack. (https://www.openssl.org/~bodo/ssl-poodle.pdf)
#
# If your infrastructure still has requirements for the vulnerable/venerable SSLV3, you can add
# "SSLv3" to the below line.
default['firezone']['ssl']['ciphers'] =
  'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA'
default['firezone']['ssl']['fips_ciphers'] = 'FIPS@STRENGTH:!aNULL:!eNULL'
default['firezone']['ssl']['protocols'] = 'TLSv1 TLSv1.1 TLSv1.2'
default['firezone']['ssl']['session_cache'] = 'shared:SSL:4m'
default['firezone']['ssl']['session_timeout'] = '5m'

# ### robots.txt Settings
#
# These control the "Allow" and "Disallow" paths in /robots.txt. See
# http://www.robotstxt.org/robotstxt.html for more information. Only a single
# line for each item is supported. If a value is nil, the line will not be
# present in the file.
default['firezone']['robots_allow'] = '/'
default['firezone']['robots_disallow'] = nil

# ### Outbound Email Settings
# If from_email not set, the outbound email feature will be disabled
default['firezone']['outbound_email']['from'] = nil
# If provider not set, the :sendmail delivery method will be used. Using
# the sendmail delivery method requires that a working mail transfer agent
# (usually set up with a relay host) be configured on this machine.
default['firezone']['outbound_email']['provider'] = nil
# Configure one or more providers below.
# See the Swoosh library documentation for more information on configuring adapters:
# https://github.com/swoosh/swoosh#adapters
default['firezone']['outbound_email']['configs'] = {
  smtp: {
    # only relay is required, but you will need some combination of the rest
    relay: 'smtp.example.com',
    port: 587, # integer
    username: '', # needs to be string if present
    password: '', # needs to be string if present
    ssl: true, # boolean
    tls: :always, # always / never / if_available
    auth: :always, # always / never / if_available
    no_mx_lookup: false, # boolean
    retries: 2 # integer
  },
  mailgun: {
    # both are required
    apikey: nil,
    domain: nil # example.com
  },
  mandrill: {
    api_key: nil
  },
  sendgrid: {
    api_key: nil
  },
  post_mark: {
    api_key: nil
  },
  sendmail: {
    cmd_path: '/usr/bin/sendmail',
    cmd_args: '-N delay,failure,success'
  }
}

# ## Telemetry
#
# Firezone relies heavily on hashed, anonymized telemetry data to help us build
# a better product for our users. This data is stored securely and is not
# shared or accessible to any third parties. Set this to false to disable.
default['firezone']['telemetry']['enabled'] = true

# ## Diagnostics Settings

# ### Connectivity Checks
#
# By default, Firezone periodically checks for WAN connectivity to the Internet
# by issuing a POST request with an empty body to https://ping.firez.one. This
# is used to determine the server's publicly routable IP address for populating
# device configurations and setting up firewall rules. Set this to false to
# disable.
default['firezone']['connectivity_checks']['enabled'] = true

# Amount of time to sleep between connectivity checks, in seconds.
# Default: 3600 (1 hour). Minimum: 60 (1 minute). Maximum: 86400 (1 day).
default['firezone']['connectivity_checks']['interval'] = 3_600
