# frozen_string_literal: true

#
# Cookbook:: firezone
# Recipe:: nginx
#
# Copyright:: 2014 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe 'firezone::config'

[node['firezone']['nginx']['cache']['directory'],
 node['firezone']['nginx']['log_directory'],
 node['firezone']['nginx']['directory'],
 "#{node['firezone']['nginx']['directory']}/conf.d",
 "#{node['firezone']['nginx']['directory']}/sites-enabled",
 "#{node['firezone']['var_directory']}/nginx/acme_root",
 "#{node['firezone']['var_directory']}/nginx/acme_root/.well-known",
 "#{node['firezone']['var_directory']}/nginx/acme_root/.well-known/acme-challenge"].each do |dir|
  directory dir do
    owner node['firezone']['user']
    group node['firezone']['group']
    mode '0700'
    recursive true
  end
end

# Link the mime.types
link "#{node['firezone']['nginx']['directory']}/mime.types" do
  to "#{node['firezone']['install_directory']}/embedded/conf/mime.types"
end

template 'nginx.conf' do
  path "#{node['firezone']['nginx']['directory']}/nginx.conf"
  source 'nginx.conf.erb'
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
  variables(
    logging_enabled: node['firezone']['logging']['enabled'],
    nginx: node['firezone']['nginx']
  )
end

template 'redirect.conf' do
  path "#{node['firezone']['nginx']['directory']}/redirect.conf"
  source 'redirect.conf.erb'
  owner 'root'
  group node['firezone']['group']
  mode '0640'
  variables(
    server_name: URI.parse(node['firezone']['external_url']).host,
    acme_www_root: "#{node['firezone']['var_directory']}/nginx/acme_root",
    non_ssl_port: node['firezone']['nginx']['non_ssl_port'],
    rate_limiting_zone_name: node['firezone']['nginx']['rate_limiting_zone_name']
  )
end

if node['firezone']['nginx']['enabled']
  component_runit_service 'nginx' do
    package 'firezone'
    action :enable
    subscribes :restart, 'template[nginx.conf]'
    subscribes :restart, 'template[phoenix.nginx.conf]'
    subscribes :restart, 'template[acme.conf]'
  end
else
  runit_service 'nginx' do
    action :disable
  end
end

# setup log rotation with logrotate because nginx and runit's svlogd
# differ in opinion about who does the logging
template "#{node['firezone']['var_directory']}/etc/logrotate.d/nginx" do
  source 'logrotate-rule.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(
    'log_directory' => node['firezone']['nginx']['log_directory'],
    'log_rotation' => node['firezone']['nginx']['log_rotation'],
    'postrotate' => "#{node['firezone']['install_directory']}/embedded/sbin/nginx -c "\
      "#{node['firezone']['nginx']['directory']}/nginx.conf -s reopen",
    'owner' => 'root',
    'group' => 'root'
  )
end
