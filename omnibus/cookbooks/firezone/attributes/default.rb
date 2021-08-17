# # Firezone configuration
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
#     { "redis": { "enable": false } }
#
# for example, it will set the node['firezone']['redis'] attribute to false.

# ## Common Use Cases
#
# These are examples of things you may want to do, depending on how you set up
# the application to run.
#
# ### Chef Identity
#
# You will have to set this up in order to log into Firezone and upload
# cookbooks with your Chef server keys.
#
# See the "Chef OAuth2 Settings" section below
#
# ### Using an external Postgres database
#
# Disable the provided Postgres instance and connect to your own:
#
# default['firezone']['postgresql']['enable'] = false
# default['firezone']['database']['user'] = 'my_db_user_name'
# default['firezone']['database']['name'] = 'my_db_name''
# default['firezone']['database']['host'] = 'my.db.server.address'
# default['firezone']['database']['port'] = 5432
#
# ### Using an external Redis server
#
# Disable the provided Redis server and use on reachable on your network:
#
# default['firezone']['redis']['enable'] = false
# default['firezone']['redis_url'] = 'redis://my.redis.host:6379/0/mydbname
#
# ### Bring your on SSL certificate
#
# If a key and certificate are not provided, a self-signed certificate will be
# generated. To use your own, provide the paths to them and ensure SSL is
# enabled in Nginx:
#
# default['firezone']['nginx']['force_ssl'] = true
# default['firezone']['ssl']['certificate'] = '/path/to/my.crt'
# default['firezone']['ssl']['certificate_key'] = '/path/to/my.key'

# ## Top-level attributes
#
# These are used by the other items below. More app-specific top-level
# attributes are further down in this file.

# The fully qualified domain name. Will use the node's fqdn if nothing is
# specified.
default['firezone']['fqdn'] = (node['fqdn'] || node['hostname']).downcase

# The URL for the Chef server. Used with the "Chef OAuth2 Settings" and
# "Chef URL Settings" below. If this is not set, authentication and some of the
# links in the application will not work.
default['firezone']['chef_server_url'] = nil

default['firezone']['config_directory'] = '/etc/firezone'
default['firezone']['install_directory'] = '/opt/firezone'
default['firezone']['app_directory'] = "#{node['firezone']['install_directory']}/embedded/service/firezone"
default['firezone']['log_directory'] = '/var/log/firezone'
default['firezone']['var_directory'] = '/var/opt/firezone'
default['firezone']['data_directory'] = '/var/opt/firezone/data'
default['firezone']['user'] = 'firezone'
default['firezone']['group'] = 'firezone'

# ## Enterprise
#
# The "enterprise" cookbook provides recipes and resources we can use for this
# app.

default['enterprise']['name'] = 'firezone'

# Enterprise uses install_path internally, but we use install_directory because
# it's more consistent. Alias it here so both work.
default['firezone']['install_path'] = node['firezone']['install_directory']

# An identifier used in /etc/inittab (default is 'SV'). Needs to be a unique
# (for the file) sequence of 1-4 characters.
default['firezone']['sysvinit_id'] = 'SUP'

# ## Nginx

# These attributes control Firezone-specific portions of the Nginx
# configuration and the virtual host for the Firezone Rails app.
default['firezone']['nginx']['enable'] = true
default['firezone']['nginx']['force_ssl'] = true
default['firezone']['nginx']['non_ssl_port'] = 80
default['firezone']['nginx']['ssl_port'] = 443
default['firezone']['nginx']['directory'] = "#{node['firezone']['var_directory']}/nginx/etc"
default['firezone']['nginx']['log_directory'] = "#{node['firezone']['log_directory']}/nginx"
default['firezone']['nginx']['log_rotation']['file_maxbytes'] = 104857600
default['firezone']['nginx']['log_rotation']['num_to_keep'] = 10
default['firezone']['nginx']['log_x_forwarded_for'] = false

# Redirect to the FQDN
default['firezone']['nginx']['redirect_to_canonical'] = true

# Controls nginx caching, used to cache some endpoints
default['firezone']['nginx']['cache']['enable'] = false
default['firezone']['nginx']['cache']['directory'] = "#{node['firezone']['var_directory']}/nginx//cache"

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
default['firezone']['nginx']['gzip_types'] = %w(
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
)
default['firezone']['nginx']['gzip_min_length'] = 1000
default['firezone']['nginx']['gzip_disable'] = 'MSIE [1-6]\.'
default['firezone']['nginx']['keepalive'] = 'on'
default['firezone']['nginx']['keepalive_timeout'] = 65
default['firezone']['nginx']['worker_processes'] = node['cpu'] && node['cpu']['total'] ? node['cpu']['total'] : 1
default['firezone']['nginx']['worker_connections'] = 1024
default['firezone']['nginx']['worker_rlimit_nofile'] = nil
default['firezone']['nginx']['multi_accept'] = false
default['firezone']['nginx']['event'] = nil
default['firezone']['nginx']['server_tokens'] = nil
default['firezone']['nginx']['server_names_hash_bucket_size'] = 64
default['firezone']['nginx']['sendfile'] = 'on'
default['firezone']['nginx']['access_log_options'] = nil
default['firezone']['nginx']['error_log_options'] = nil
default['firezone']['nginx']['disable_access_log'] = false
default['firezone']['nginx']['default_site_enabled'] = false
default['firezone']['nginx']['types_hash_max_size'] = 2048
default['firezone']['nginx']['types_hash_bucket_size'] = 64
default['firezone']['nginx']['proxy_read_timeout'] = nil
default['firezone']['nginx']['client_body_buffer_size'] = nil
default['firezone']['nginx']['client_max_body_size'] = '250m'
default['firezone']['nginx']['default']['modules'] = []

# ## Postgres

default['firezone']['postgresql']['enable'] = true
default['firezone']['postgresql']['username'] = node['firezone']['user']
default['firezone']['postgresql']['data_directory'] = "#{node['firezone']['var_directory']}/postgresql/9.3/data"

# ### Logs
default['firezone']['postgresql']['log_directory'] = "#{node['firezone']['log_directory']}/postgresql"
default['firezone']['postgresql']['log_rotation']['file_maxbytes'] = 104857600
default['firezone']['postgresql']['log_rotation']['num_to_keep'] = 10

# ### DB settings
default['firezone']['postgresql']['checkpoint_completion_target'] = 0.5
default['firezone']['postgresql']['checkpoint_segments'] = 3
default['firezone']['postgresql']['checkpoint_timeout'] = '5min'
default['firezone']['postgresql']['checkpoint_warning'] = '30s'
default['firezone']['postgresql']['effective_cache_size'] = '128MB'
default['firezone']['postgresql']['listen_address'] = '127.0.0.1'
default['firezone']['postgresql']['max_connections'] = 350
default['firezone']['postgresql']['md5_auth_cidr_addresses'] = ['127.0.0.1/32', '::1/128']
default['firezone']['postgresql']['port'] = 15432
default['firezone']['postgresql']['shared_buffers'] = "#{(node['memory']['total'].to_i / 4) / 1024}MB"
default['firezone']['postgresql']['shmmax'] = 17179869184
default['firezone']['postgresql']['shmall'] = 4194304
default['firezone']['postgresql']['work_mem'] = '8MB'

# ## Rails
#
# The Rails app for Firezone
default['firezone']['rails']['enable'] = true
default['firezone']['rails']['port'] = 13000
default['firezone']['rails']['log_directory'] = "#{node['firezone']['log_directory']}/rails"
default['firezone']['rails']['log_rotation']['file_maxbytes'] = 104857600
default['firezone']['rails']['log_rotation']['num_to_keep'] = 10

# ## Redis

default['firezone']['redis']['enable'] = true
default['firezone']['redis']['bind'] = '127.0.0.1'
default['firezone']['redis']['directory'] = "#{node['firezone']['var_directory']}/redis"
default['firezone']['redis']['log_directory'] = "#{node['firezone']['log_directory']}/redis"
default['firezone']['redis']['log_rotation']['file_maxbytes'] = 104857600
default['firezone']['redis']['log_rotation']['num_to_keep'] = 10
default['firezone']['redis']['port'] = 16379

# ## Runit

# This is missing from the enterprise cookbook
# see (https://github.com/chef-cookbooks/enterprise-chef-common/pull/17)
#
# Will be copied to the root node.runit namespace.
default['firezone']['runit']['svlogd_bin'] = "#{node['firezone']['install_directory']}/embedded/bin/svlogd"

# ## Sidekiq
#
# Used for background jobs

default['firezone']['sidekiq']['enable'] = true
default['firezone']['sidekiq']['concurrency'] = 25
default['firezone']['sidekiq']['log_directory'] = "#{node['firezone']['log_directory']}/sidekiq"
default['firezone']['sidekiq']['log_rotation']['file_maxbytes'] = 104857600
default['firezone']['sidekiq']['log_rotation']['num_to_keep'] = 10
default['firezone']['sidekiq']['timeout'] = 30

# ## SSL

default['firezone']['ssl']['directory'] = '/var/opt/firezone/ssl'

# Paths to the SSL certificate and key files. If these are not provided we will
# attempt to generate a self-signed certificate and use that instead.
default['firezone']['ssl']['enabled'] = true
default['firezone']['ssl']['certificate'] = nil
default['firezone']['ssl']['certificate_key'] = nil
default['firezone']['ssl']['ssl_dhparam'] = nil

# These are used in creating a self-signed cert if you haven't brought your own.
default['firezone']['ssl']['country_name'] = 'US'
default['firezone']['ssl']['state_name'] = 'WA'
default['firezone']['ssl']['locality_name'] = 'Seattle'
default['firezone']['ssl']['company_name'] = 'My Firezone'
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
default['firezone']['ssl']['ciphers'] = 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA'
default['firezone']['ssl']['fips_ciphers'] = 'FIPS@STRENGTH:!aNULL:!eNULL'
default['firezone']['ssl']['protocols'] = 'TLSv1 TLSv1.1 TLSv1.2'
default['firezone']['ssl']['session_cache'] = 'shared:SSL:4m'
default['firezone']['ssl']['session_timeout'] = '5m'

# ## Unicorn
#
# Settings for main Rails app Unicorn application server. These attributes are
# used with the template from the community Unicorn cookbook:
# https://github.com/chef-cookbooks/unicorn/blob/master/templates/default/unicorn.rb.erb
#
# Full explanation of all options can be found at
# http://unicorn.bogomips.org/Unicorn/Configurator.html

default['firezone']['unicorn']['name'] = 'firezone'
default['firezone']['unicorn']['copy_on_write'] = true
default['firezone']['unicorn']['enable_stats'] = false
default['firezone']['unicorn']['forked_user'] = node['firezone']['user']
default['firezone']['unicorn']['forked_group'] = node['firezone']['group']
default['firezone']['unicorn']['listen'] = ["127.0.0.1:#{node['firezone']['rails']['port']}"]
default['firezone']['unicorn']['pid'] = "#{node['firezone']['var_directory']}/rails/run/unicorn.pid"
default['firezone']['unicorn']['preload_app'] = true
default['firezone']['unicorn']['worker_timeout'] = 15
default['firezone']['unicorn']['worker_processes'] = node['cpu'] && node['cpu']['total'] ? node['cpu']['total'] : 1

# These are not used, but you can set them if needed
default['firezone']['unicorn']['before_exec'] = nil
default['firezone']['unicorn']['stderr_path'] = nil
default['firezone']['unicorn']['stdout_path'] = nil
default['firezone']['unicorn']['unicorn_command_line'] = nil
default['firezone']['unicorn']['working_directory'] = nil

# These are defined a recipe to be specific things we need that you
# could change here, but probably should not.
default['firezone']['unicorn']['before_fork'] = nil
default['firezone']['unicorn']['after_fork'] = nil

# ## Database

default['firezone']['database']['user'] = node['firezone']['postgresql']['username']
default['firezone']['database']['name'] = 'firezone'
default['firezone']['database']['host'] = node['firezone']['postgresql']['listen_address']
default['firezone']['database']['port'] = node['firezone']['postgresql']['port']
default['firezone']['database']['pool'] = node['firezone']['sidekiq']['concurrency']
default['firezone']['database']['extensions'] = { 'plpgsql' => true, 'pg_trgm' => true }

# ## App-specific top-level attributes
#
# These are used by Rails and Sidekiq. Most will be exported directly to
# environment variables to be used by the app.
#
# Items that are set to nil here and also set in the development environment
# configuration (https://github.com/chef/firezone/blob/master/.env) will
# use the value from the development environment. Set them to something other
# than nil to change them.

default['firezone']['fieri_url'] = 'http://localhost:13000/fieri/jobs'
default['firezone']['fieri_firezone_endpoint'] = 'https://localhost:13000'
default['firezone']['fieri_key'] = nil
default['firezone']['from_email'] = nil
default['firezone']['github_access_token'] = nil
default['firezone']['github_key'] = nil
default['firezone']['github_secret'] = nil
default['firezone']['google_analytics_id'] = nil
default['firezone']['segment_write_key'] = nil
default['firezone']['newrelic_agent_enabled'] = 'false'
default['firezone']['newrelic_app_name'] = nil
default['firezone']['newrelic_license_key'] = nil
default['firezone']['datadog_tracer_enabled'] = 'false'
default['firezone']['datadog_app_name'] = nil
default['firezone']['port'] = node['firezone']['nginx']['force_ssl'] ? node['firezone']['nginx']['ssl_port'] : node['firezone']['non_ssl_port']
default['firezone']['protocol'] = node['firezone']['nginx']['force_ssl'] ? 'https' : 'http'
default['firezone']['pubsubhubbub_callback_url'] = nil
default['firezone']['pubsubhubbub_secret'] = nil
default['firezone']['redis_url'] = 'redis://127.0.0.1:16379/0/firezone'
default['firezone']['redis_jobq_url'] = nil
default['firezone']['sentry_url'] = nil
default['firezone']['api_item_limit'] = 100
default['firezone']['rails_log_to_stdout'] = true
default['firezone']['fips_enabled'] = nil

# Allow owners to remove their cookbooks, cookbook versions, or tools.
# Added as a step towards implementing RFC072 Artifact Yanking
# https://github.com/chef/chef-rfc/blob/f8250a4746d2df530b605ecfaa2dc5ae9b7dc7ff/rfc072-artifact-yanking.md
# recommend false; set to true as default for backward compatibility
default['firezone']['owners_can_remove_artifacts'] = true

# ### Chef URL Settings
#
# URLs for various links used within Firezone
#
# These have defaults in the app based on the chef_server_url along the lines of the interpolations below.
# Override if you need to set these URLs to targets other than the configured chef_server_url.
#
# default['firezone']['chef_identity_url'] = "#{node['firezone']['chef_server_url']}/id"
# default['firezone']['chef_manage_url'] = node['firezone']['chef_server_url']
# default['firezone']['chef_profile_url'] = node['firezone']['chef_server_url']
# default['firezone']['chef_sign_up_url'] = "#{node['firezone']['chef_server_url']}/signup?ref=community"

# URLs for Chef Software, Inc. sites. Most of these have defaults set in
# Firezone already, but you can customize them here to your liking
default['firezone']['chef_domain'] = 'chef.io'
default['firezone']['chef_www_url'] = 'https://www.chef.io'
#
# These have defaults in the app based on the chef_domain along the lines of the interpolations below.
# Override if you need to set these URLs to targets other than the configured chef_domain.
#
# default['firezone']['chef_blog_url'] = "https://www.#{node['firezone']['chef_domain']}/blog"
# default['firezone']['chef_docs_url'] = "https://docs.#{node['firezone']['chef_domain']}"
# default['firezone']['chef_downloads_url'] = "https://downloads.#{node['firezone']['chef_domain']}"
# default['firezone']['learn_chef_url'] = "https://learn.#{node['firezone']['chef_domain']}"

# ### Chef OAuth2 Settings
#
# These settings configure the service to talk to a Chef identity service.
#
# An Application must be created on the Chef server's identity service to do
# this. With the following in /etc/opscode/chef-server.rb:
#
#     oc_id['applications'] = { 'my_firezone' => { 'redirect_uri' => 'https://my.firezone.server.fqdn/auth/chef_oauth2/callback' } }
#
# Run `chef-server-ctl reconfigure`, then these values should available in
# /etc/opscode/oc-id-applications/my_firezone.json.
#
# The chef_oauth2_url should be the root URL of your Chef server.
#
# If you are using a self-signed certificate on your Chef server without a
# properly configured certificate authority, chef_oauth2_verify_ssl must be
# false.
default['firezone']['chef_oauth2_app_id'] = nil
default['firezone']['chef_oauth2_secret'] = nil
default['firezone']['chef_oauth2_url'] = nil
default['firezone']['chef_oauth2_verify_ssl'] = true

# ### CLA Settings
#
# These are used for the Contributor License Agreement features. You only need
# them if the cla and/or join_ccla features are enabled (see "Features" below.)
default['firezone']['ccla_version'] = nil
default['firezone']['cla_signature_notification_email'] = nil
default['firezone']['cla_report_email'] = nil
default['firezone']['curry_cla_location'] = nil
default['firezone']['curry_success_label'] = nil
default['firezone']['icla_location'] = nil
default['firezone']['icla_version'] = nil
default['firezone']['seed_cla_data'] = nil

# ### Features
#
# These control the feature flags that turn features on and off.
#
# Available features are:
#
# * announcement: Display the Firezone initial launch announcement banner
#   (this will most likely be of no use to you, but could be made a
#   configurable thing in the future.)
# * cla: Enable the Contributor License Agreement features
# * collaborator_groups: Enable collaborator groups, allowing management of collaborators through groups
# * fieri: Use the fieri service to report on cookbook quality (requires
#   fieri_url, fieri_firezone_endpoint, and fieri_key to be set.)
# * github: Enable GitHub integration, used with CLA signing
# * gravatar: Enable Gravatar integration, used for user avatars
# * join_ccla: Enable joining of Corporate CLAs
# * tools: Enable the tools section
default['firezone']['features'] = 'tools, gravatar'

# ### Air Gapped Settings
# This controls whether your Firezone will reach out to 3rd party services like certain fonts
# and Google Analytics.
default['firezone']['air_gapped'] = 'false'

# ### robots.txt Settings
#
# These control the "Allow" and "Disallow" paths in /robots.txt. See
# http://www.robotstxt.org/robotstxt.html for more information. Only a single
# line for each item is supported. If a value is nil, the line will not be
# present in the file.
default['firezone']['robots_allow'] = '/'
default['firezone']['robots_disallow'] = nil

# ### S3 Settings
#
# If these are not set, uploaded cookbooks will be stored on the local
# filesystem (this means that running multiple application servers will require
# some kind of shared storage, which is not provided.)

# #### Required S3

# If these are set, cookbooks will be uploaded to the to the given S3 bucket.
# The default is to rely on an IAM role with access to the bucket be attached to
# the compute resources running Firezone.
default['firezone']['s3_bucket'] = nil
default['firezone']['s3_region'] = nil

# #### Optional S3

# S3 Server Side Encryption can be enabled by setting to AES256
default['firezone']['s3_encryption'] = nil

# A cdn_url can be used for an alias if the S3 bucket is behind a CDN like CloudFront.
default['firezone']['cdn_url'] = nil

# If set then firezone will apply an object-level private ACL. For this to work,
# the relevant IAM and bucket policies will need to allow PutObjectACL permissions.
# Note: if this is not set, and "Block all public access" is on for the bucket then Chef
# Firezone will be unable to update cookbooks.
# default['firezone']['s3_private_objects'] = nil

# If using IAM user credentials for bucket access, set these.
default['firezone']['s3_access_key_id'] = nil
default['firezone']['s3_secret_access_key'] = nil

# By default, Firezone will use domain style S3 urls that look like this:
#
#   bucketname.s3.amazonaws.com
#
# This style of url will work across all regions.
#
# If this is set as ':s3_path_url', the S3 urls will look like this
# s3.amazonaws.com/bucketname.
# This will only work if the S3 bucket is in N. Virginia.
# If your S3 bucket name contains any periods "." - i.e. "my.bucket.name",
# you must use the path style url and your S3 bucket must be in N. Virginia
default['firezone']['s3_domain_style'] = ':s3_domain_url'

# ### SMTP Settings
#
# If none of these are set, the :sendmail delivery method will be used. Using
# the sendmail delivery method requires that a working mail transfer agent
# (usually set up with a relay host) be configured on this machine.
#
# SMTP will use the 'plain' authentication method.
default['firezone']['smtp_address'] = nil
default['firezone']['smtp_password'] = nil
default['firezone']['smtp_port'] = nil
default['firezone']['smtp_user_name'] = nil

# ### StatsD Settings
#
# If these are present, metrics can be reported to a StatsD server.
default['firezone']['statsd_url'] = nil
default['firezone']['statsd_port'] = nil
