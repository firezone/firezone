#
# Cookbook:: firezone
# Recipe:: config
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

# Get and/or create config and secrets.
#
# This creates the config_directory if it does not exist as well as the files
# in it.
Firezone::Config.load_or_create!(
  "#{node['supermarket']['config_directory']}/supermarket.rb",
  node
)
FireZone::Config.load_from_json!(
  "#{node['supermarket']['config_directory']}/supermarket.json",
  node
)
Firezone::Config.load_or_create_secrets!(
  "#{node['supermarket']['config_directory']}/secrets.json",
  node
)

Supermarket::Config.audit_config(node['supermarket'])
Supermarket::Config.maybe_turn_on_fips(node)

# Copy things we need from the supermarket namespace to the top level. This is
# necessary for some community cookbooks.
node.consume_attributes('runit' => node['supermarket']['runit'])

# set chef_oauth2_url from chef_server_url after this value has been loaded from config
if node['supermarket']['chef_server_url'] && node['supermarket']['chef_oauth2_url'].nil?
  node.default['supermarket']['chef_oauth2_url'] = node['supermarket']['chef_server_url']
end

user node['supermarket']['user']

group node['supermarket']['group'] do
  members [node['supermarket']['user']]
end

directory node['supermarket']['config_directory'] do
  owner node['supermarket']['user']
  group node['supermarket']['group']
end

directory node['supermarket']['var_directory'] do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0700'
  recursive true
end

directory node['supermarket']['log_directory'] do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0700'
  recursive true
end

directory "#{node['supermarket']['var_directory']}/etc" do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0700'
end

file "#{node['supermarket']['config_directory']}/supermarket.rb" do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
end

file "#{node['supermarket']['config_directory']}/secrets.json" do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
end
