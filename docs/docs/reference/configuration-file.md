---
layout: default
nav_order: 2
title: Configuration File
parent: Reference
---

Shown below is a complete listing of the configuration options available in
`/etc/firezone/firezone.rb`.

| option                             | description           | default value   |
| ----------------------------------------- | --------------------- | -------- |
| `default['firezone']['nginx']['enabled']` | Whether to enable the bundled nginx server | `true` |
| default['firezone']['fqdn'] = (node['fqdn'] \|\| node['hostname']).downcase |||
| default['firezone']['config_directory'] = '/etc/firezone' |||
| default['firezone']['install_directory'] = '/opt/firezone' |||
| default['firezone']['app_directory'] = "#{node['firezone']['install_directory']}/embedded/service/firezone" |||
| default['firezone']['log_directory'] = '/var/log/firezone' |||
| default['firezone']['var_directory'] = '/var/opt/firezone' |||
| default['firezone']['user'] = 'firezone' |||
| default['firezone']['group'] = 'firezone' |||
| default['firezone']['admin_email'] = "firezone@localhost" |||
| default['firezone']['egress_interface'] = nil |||
| default['firezone']['fips_enabled'] = nil |||
| default['enterprise']['name'] = 'firezone' |||
| default['firezone']['install_path'] = node['firezone']['install_directory'] |||
| default['firezone']['sysvinit_id'] = 'SUP' |||
| default['firezone']['nginx']['enabled'] = true |||
| default['firezone']['nginx']['force_ssl'] = true |||
| default['firezone']['nginx']['non_ssl_port'] = 80 |||
| default['firezone']['nginx']['ssl_port'] = 443 |||
| default['firezone']['nginx']['directory'] = "#{node['firezone']['var_directory']}/nginx/etc" |||
| default['firezone']['nginx']['log_directory'] = "#{node['firezone']['log_directory']}/nginx" |||
| default['firezone']['nginx']['log_rotation']['file_maxbytes'] = 104857600 |||
| default['firezone']['nginx']['log_rotation']['num_to_keep'] = 10 |||
| default['firezone']['nginx']['log_x_forwarded_for'] = false |||
| default['firezone']['nginx']['redirect_to_canonical'] = false |||
| default['firezone']['nginx']['cache']['enabled'] = false |||
| default['firezone']['nginx']['cache']['directory'] = "#{node['firezone']['var_directory']}/nginx/cache" |||
| default['firezone']['nginx']['user'] = node['firezone']['user'] |||
| default['firezone']['nginx']['group'] = node['firezone']['group'] |||
| default['firezone']['nginx']['dir'] = node['firezone']['nginx']['directory'] |||
| default['firezone']['nginx']['log_dir'] = node['firezone']['nginx']['log_directory'] |||
| default['firezone']['nginx']['pid'] = "#{node['firezone']['nginx']['directory']}/nginx.pid" |||
| default['firezone']['nginx']['daemon_disable'] = true |||
| default['firezone']['nginx']['gzip'] = 'on' |||
| default['firezone']['nginx']['gzip_static'] = 'off' |||
| default['firezone']['nginx']['gzip_http_version'] = '1.0' |||
| default['firezone']['nginx']['gzip_comp_level'] = '2' |||
| default['firezone']['nginx']['gzip_proxied'] = 'any' |||
| default['firezone']['nginx']['gzip_vary'] = 'off' |||
| default['firezone']['nginx']['gzip_buffers'] = nil |||
| default['firezone']['nginx']['gzip_types'] = %w( |||
|   text/plain |||
|   text/css |||
|   application/x-javascript |||
|   text/xml |||
|   application/xml |||
|   application/rss+xml |||
|   application/atom+xml |||
|   text/javascript |||
|   application/javascript |||
|   application/json |||
| ) |||
| default['firezone']['nginx']['gzip_min_length'] = 1000 |||
| default['firezone']['nginx']['gzip_disable'] = 'MSIE [1-6]\.' |||
| default['firezone']['nginx']['keepalive'] = 'on' |||
| default['firezone']['nginx']['keepalive_timeout'] = 65 |||
| default['firezone']['nginx']['worker_processes'] = node['cpu'] && node['cpu']['total'] ? node['cpu']['total'] : 1 |||
| default['firezone']['nginx']['worker_connections'] = 1024 |||
| default['firezone']['nginx']['worker_rlimit_nofile'] = nil |||
| default['firezone']['nginx']['multi_accept'] = false |||
| default['firezone']['nginx']['event'] = nil |||
| default['firezone']['nginx']['server_tokens'] = nil |||
| default['firezone']['nginx']['server_names_hash_bucket_size'] = 64 |||
| default['firezone']['nginx']['sendfile'] = 'on' |||
| default['firezone']['nginx']['access_log_options'] = nil |||
| default['firezone']['nginx']['error_log_options'] = nil |||
| default['firezone']['nginx']['disable_access_log'] = false |||
| default['firezone']['nginx']['default_site_enabled'] = false |||
| default['firezone']['nginx']['types_hash_max_size'] = 2048 |||
| default['firezone']['nginx']['types_hash_bucket_size'] = 64 |||
| default['firezone']['nginx']['proxy_read_timeout'] = nil |||
| default['firezone']['nginx']['client_body_buffer_size'] = nil |||
| default['firezone']['nginx']['client_max_body_size'] = '250m' |||
| default['firezone']['nginx']['default']['modules'] = [] |||
| default['firezone']['postgresql']['enabled'] = true |||
| default['firezone']['postgresql']['username'] = node['firezone']['user'] |||
| default['firezone']['postgresql']['data_directory'] = "#{node['firezone']['var_directory']}/postgresql/13.3/data" |||
| default['firezone']['postgresql']['log_directory'] = "#{node['firezone']['log_directory']}/postgresql" |||
| default['firezone']['postgresql']['log_rotation']['file_maxbytes'] = 104857600 |||
| default['firezone']['postgresql']['log_rotation']['num_to_keep'] = 10 |||
| default['firezone']['postgresql']['checkpoint_completion_target'] = 0.5 |||
| default['firezone']['postgresql']['checkpoint_segments'] = 3 |||
| default['firezone']['postgresql']['checkpoint_timeout'] = '5min' |||
| default['firezone']['postgresql']['checkpoint_warning'] = '30s' |||
| default['firezone']['postgresql']['effective_cache_size'] = '128MB' |||
| default['firezone']['postgresql']['listen_address'] = '127.0.0.1' |||
| default['firezone']['postgresql']['max_connections'] = 350 |||
| default['firezone']['postgresql']['md5_auth_cidr_addresses'] = ['127.0.0.1/32', '::1/128'] |||
| default['firezone']['postgresql']['port'] = 15432 |||
| default['firezone']['postgresql']['shared_buffers'] = "#{(node['memory']['total'].to_i / 4) / 1024}MB" |||
| default['firezone']['postgresql']['shmmax'] = 17179869184 |||
| default['firezone']['postgresql']['shmall'] = 4194304 |||
| default['firezone']['postgresql']['work_mem'] = '8MB' |||
| default['firezone']['database']['user'] = node['firezone']['postgresql']['username'] |||
| default['firezone']['database']['name'] = 'firezone' |||
| default['firezone']['database']['host'] = node['firezone']['postgresql']['listen_address'] |||
| default['firezone']['database']['port'] = node['firezone']['postgresql']['port'] |||
| default['firezone']['database']['pool'] = [10, Etc.nprocessors].max |||
| default['firezone']['database']['extensions'] = { 'plpgsql' => true, 'pg_trgm' => true } |||
| default['firezone']['phoenix']['enabled'] = true |||
| default['firezone']['phoenix']['port'] = 13000 |||
| default['firezone']['phoenix']['log_directory'] = "#{node['firezone']['log_directory']}/phoenix" |||
| default['firezone']['phoenix']['log_rotation']['file_maxbytes'] = 104857600 |||
| default['firezone']['phoenix']['log_rotation']['num_to_keep'] = 10 |||
| default['firezone']['wireguard']['enabled'] = true |||
| default['firezone']['wireguard']['log_directory'] = "#{node['firezone']['log_directory']}/wireguard" |||
| default['firezone']['wireguard']['log_rotation']['file_maxbytes'] = 104857600 |||
| default['firezone']['wireguard']['log_rotation']['num_to_keep'] = 10 |||
| default['firezone']['wireguard']['interface_name'] = 'wg-firezone' |||
| default['firezone']['wireguard']['port'] = 51820 |||
| default['firezone']['wireguard']['mtu'] = 1420 |||
| default['firezone']['wireguard']['ipv4']['enabled'] = true |||
| default['firezone']['wireguard']['ipv4']['network'] = '10.3.2.0/24' |||
| default['firezone']['wireguard']['ipv4']['address'] = '10.3.2.1' |||
| default['firezone']['wireguard']['ipv6']['enabled'] = true |||
| default['firezone']['wireguard']['ipv6']['network'] = 'fd00::3:2:0/120' |||
| default['firezone']['wireguard']['ipv6']['address'] = 'fd00::3:2:1' |||
| default['firezone']['runit']['svlogd_bin'] = "#{node['firezone']['install_directory']}/embedded/bin/svlogd" |||
| default['firezone']['ssl']['directory'] = '/var/opt/firezone/ssl' |||
| default['firezone']['ssl']['enabled'] = true |||
| default['firezone']['ssl']['certificate'] = nil |||
| default['firezone']['ssl']['certificate_key'] = nil |||
| default['firezone']['ssl']['ssl_dhparam'] = nil |||
| default['firezone']['ssl']['country_name'] = 'US' |||
| default['firezone']['ssl']['state_name'] = 'CA' |||
| default['firezone']['ssl']['locality_name'] = 'San Francisco' |||
| default['firezone']['ssl']['company_name'] = 'My Company' |||
| default['firezone']['ssl']['organizational_unit_name'] = 'Operations' |||
| default['firezone']['ssl']['email_address'] = 'you@example.com' |||
| default['firezone']['ssl']['ciphers'] = 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA:AES:CAMELLIA:DES-CBC3-SHA:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK:!aECDH:!EDH-DSS-DES-CBC3-SHA:!EDH-RSA-DES-CBC3-SHA:!KRB5-DES-CBC3-SHA' |||
| default['firezone']['ssl']['fips_ciphers'] = 'FIPS@STRENGTH:!aNULL:!eNULL' |||
| default['firezone']['ssl']['protocols'] = 'TLSv1 TLSv1.1 TLSv1.2' |||
| default['firezone']['ssl']['session_cache'] = 'shared:SSL:4m' |||
| default['firezone']['ssl']['session_timeout'] = '5m' |||
| default['firezone']['robots_allow'] = '/' |||
| default['firezone']['robots_disallow'] = nil |||
| default['firezone']['from_email'] = nil |||
| default['firezone']['smtp_address'] = nil |||
| default['firezone']['smtp_password'] = nil |||
| default['firezone']['smtp_port'] = nil |||
| default['firezone']['smtp_user_name'] = nil |||
| default['firezone']['connectivity_checks']['enabled'] = true |||
| default['firezone']['connectivity_checks']['interval'] = 3_600 |||
