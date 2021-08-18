#
# Cookbook:: supermarket
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

include_recipe 'omnibus-supermarket::config'

[node['supermarket']['nginx']['cache']['directory'],
 node['supermarket']['nginx']['log_directory'],
 node['supermarket']['nginx']['directory'],
 "#{node['supermarket']['nginx']['directory']}/conf.d",
 "#{node['supermarket']['nginx']['directory']}/sites-enabled"].each do |dir|
  directory dir do
    owner node['supermarket']['user']
    group node['supermarket']['group']
    mode '0700'
    recursive true
  end
end

# Link the mime.types
link "#{node['supermarket']['nginx']['directory']}/mime.types" do
  to "#{node['supermarket']['install_directory']}/embedded/conf/mime.types"
end

template 'nginx.conf' do
  path "#{node['supermarket']['nginx']['directory']}/nginx.conf"
  source 'nginx.conf.erb'
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
  variables(nginx: node['supermarket']['nginx'])
end

if node['supermarket']['nginx']['enable']
  component_runit_service 'nginx' do
    package 'supermarket'
    action :enable
    subscribes :restart, 'template[nginx.conf]'
    subscribes :restart, 'template[phoenix.nginx.conf]'
  end
else
  runit_service 'nginx' do
    action :disable
  end
end

# setup log rotation with logrotate because nginx and runit's svlogd
# differ in opinion about who does the logging
template "#{node['supermarket']['var_directory']}/etc/logrotate.d/nginx" do
  source 'logrotate-rule.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(
    'log_directory' => node['supermarket']['nginx']['log_directory'],
    'log_rotation' => node['supermarket']['nginx']['log_rotation'],
    'postrotate' => "#{node['supermarket']['install_directory']}/embedded/sbin/nginx -c #{node['supermarket']['nginx']['directory']}/nginx.conf -s reopen",
    'owner' => 'root',
    'group' => 'root'
  )
end
