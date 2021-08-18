#
# Cookbook:: firezone
# Recipe:: phoenix
#
# Copyright:: 2014 Chef Software, Inc.
# Copyright:: 2021 FireZone
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

include_recipe 'omnibus-supermarket::config'
include_recipe 'omnibus-supermarket::nginx'

[node['supermarket']['phoenix']['log_directory'],
 "#{node['supermarket']['var_directory']}/rails/run"].each do |dir|
  directory dir do
    owner node['supermarket']['user']
    group node['supermarket']['group']
    mode '0700'
    recursive true
  end
end

template 'unicorn.rb' do
  path "#{node['supermarket']['var_directory']}/etc/unicorn.rb"
  source 'unicorn.rb.erb'
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
  variables(node['supermarket']['unicorn'].to_hash)
end

template 'phoenix.nginx.conf' do
  path "#{node['supermarket']['nginx']['directory']}/sites-enabled/rails"
  source 'rails.nginx.conf.erb'
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
  variables(nginx: node['supermarket']['nginx'],
            phoenix: node['supermarket']['phoenix'],
            fqdn: node['supermarket']['fqdn'],
            fips_enabled: node['supermarket']['fips_enabled'],
            ssl: node['supermarket']['ssl'],
            app_directory: node['supermarket']['app_directory'])
end

if node['supermarket']['phoenix']['enable']
  component_runit_service 'phoenix' do
    package 'firezone'
    action :enable
    subscribes :restart, 'template[unicorn.rb]'
    subscribes :restart, 'file[environment-variables]'
  end
else
  runit_service 'phoenix' do
    action :disable
  end
end
