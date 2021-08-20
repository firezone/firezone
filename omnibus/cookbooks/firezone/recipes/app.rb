#
# Cookbook:: firezone
# Recipe:: app
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

# Common configuration for Phoenix

include_recipe 'firezone::config'
include_recipe 'firezone::phoenix'

execute 'fix app permissions' do
  app_dir = node['firezone']['app_directory']
  user = node['firezone']['user']
  group = node['firezone']['group']
  command "chown -R #{user}:#{group} #{app_dir}"
  command "chmod -R o-rwx #{app_dir}"
  command "chmod -R g-rwx #{app_dir}"
end

file 'environment-variables' do
  path "#{node['firezone']['var_directory']}/etc/env"
  attributes = node['firezone'].merge(
    'force_ssl' => node['firezone']['nginx']['force_ssl']
  )
  content Firezone::Config.environment_variables_from(attributes)
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end

execute 'database schema' do
  command 'bin/firezone eval "FzHttp.Release.migrate"'
  cwd node['firezone']['app_directory']
  environment(Firezone::Config.app_env(node['firezone']))
  user node['firezone']['user']
end
