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

include_recipe 'omnibus-supermarket::config'
include_recipe 'omnibus-supermarket::phoenix'

file 'environment-variables' do
  path "#{node['supermarket']['var_directory']}/etc/env"
  content Supermarket::Config.environment_variables_from(node['supermarket'].merge('force_ssl' => node['supermarket']['nginx']['force_ssl']))
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
end

link "#{node['supermarket']['app_directory']}/.env.production" do
  to "#{node['supermarket']['var_directory']}/etc/env"
end

file "#{node['supermarket']['var_directory']}/etc/database.yml" do
  content(YAML.dump({
    'production' => {
      'adapter' => 'postgresql',
      'database' => node['supermarket']['database']['name'],
      'username' => node['supermarket']['database']['user'],
      'password' => node['supermarket']['database']['password'],
      'host' => node['supermarket']['database']['host'],
      'port' => node['supermarket']['database']['port'],
      'pool' => node['supermarket']['database']['pool'],
    }
  }))
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0600'
end

link "#{node['supermarket']['app_directory']}/config/database.yml" do
  to "#{node['supermarket']['var_directory']}/etc/database.yml"
end

# Ensure the db schema is owned by the supermarket user, so dumping the db
# schema after migrate works
file "#{node['supermarket']['app_directory']}/db/schema.rb" do
  owner node['supermarket']['user']
end

execute 'database schema' do
  command 'bundle exec rake db:migrate db:seed'
  cwd node['supermarket']['app_directory']
  environment(
    'RAILS_ENV' => 'production',
    'HOME' => node['supermarket']['app_directory']
  )
  user node['supermarket']['user']
end

# tar files for cookbooks are uploaded to /opt/supermarket/embedded/service/supermarket/public/system
directory node['supermarket']['data_directory'] do
  owner node['supermarket']['user']
  group node['supermarket']['group']
  mode '0755'
  action :create
end

link "#{node['supermarket']['app_directory']}/public/system" do
  to node['supermarket']['data_directory']
end

sitemap_files = ['sitemap.xml.gz', 'sitemap1.xml.gz']
sitemap_files.each do |sitemap_file|
  file "#{node['supermarket']['app_directory']}/public/#{sitemap_file}" do
    owner node['supermarket']['user']
    group node['supermarket']['group']
    mode '0664'
    action :create
  end
end
