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

fqdn = URI.parse(node['firezone']['external_url']).host
email_address = node['firezone']['ssl']['email_address']
server = node['firezone']['ssl']['acme_server']
acme_root_dir = "#{node['firezone']['var_directory']}/#{fqdn}/#{email_address}/#{server}"

[node['firezone']['nginx']['cache']['directory'],
 node['firezone']['nginx']['log_directory'],
 node['firezone']['nginx']['directory'],
 acme_root_dir,
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
  acme_enabled = node['firezone']['ssl']['acme'] && !node['firezone']['ssl']['certificate']
  path "#{node['firezone']['nginx']['directory']}/nginx.conf"
  source 'nginx.conf.erb'
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
  variables(
    logging_enabled: node['firezone']['logging']['enabled'],
    nginx: node['firezone']['nginx'],
    acme_path: "#{acme_root_dir}/acme/acme.conf",
    acme_enabled: acme_enabled
  )
end

template 'acme.conf' do
  path "#{acme_root_dir}/acme/acme.conf"
  source 'acme.conf.erb'
  owner 'root'
  group node['firezone']['group']
  mode '0640'
  variables(
    server_name: fqdn,
    acme_www_root: "#{node['firezone']['var_directory']}/nginx/acme_root"
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
