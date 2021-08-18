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

file 'environment-variables' do
  path "#{node['firezone']['var_directory']}/etc/env"
  content Firezone::Config.environment_variables_from(node['firezone'].merge('force_ssl' => node['firezone']['nginx']['force_ssl']))
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end

link "#{node['firezone']['app_directory']}/.env.production" do
  to "#{node['firezone']['var_directory']}/etc/env"
end

file "#{node['firezone']['var_directory']}/etc/database.yml" do
  content(YAML.dump({
    'production' => {
      'adapter' => 'postgresql',
      'database' => node['firezone']['database']['name'],
      'username' => node['firezone']['database']['user'],
      'password' => node['firezone']['database']['password'],
      'host' => node['firezone']['database']['host'],
      'port' => node['firezone']['database']['port'],
      'pool' => node['firezone']['database']['pool'],
    }
  }))
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0600'
end

link "#{node['firezone']['app_directory']}/config/database.yml" do
  to "#{node['firezone']['var_directory']}/etc/database.yml"
end

# Ensure the db schema is owned by the firezone user, so dumping the db
# schema after migrate works
file "#{node['firezone']['app_directory']}/db/schema.rb" do
  owner node['firezone']['user']
end

execute 'database schema' do
  command 'bundle exec rake db:migrate db:seed'
  cwd node['firezone']['app_directory']
  environment(
    'MIX_ENV' => 'production',
    'HOME' => node['firezone']['app_directory']
  )
  user node['firezone']['user']
end

# tar files for cookbooks are uploaded to /opt/firezone/embedded/service/firezone/public/system
directory node['firezone']['data_directory'] do
  owner node['firezone']['user']
  group node['firezone']['group']
  mode '0755'
  action :create
end

link "#{node['firezone']['app_directory']}/public/system" do
  to node['firezone']['data_directory']
end

sitemap_files = ['sitemap.xml.gz', 'sitemap1.xml.gz']
sitemap_files.each do |sitemap_file|
  file "#{node['firezone']['app_directory']}/public/#{sitemap_file}" do
    owner node['firezone']['user']
    group node['firezone']['group']
    mode '0664'
    action :create
  end
end
