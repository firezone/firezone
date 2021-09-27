#
# Cookbook:: firezone
# Recipe:: database
#
# Copyright:: 2014 Chef Software, Inc.
# Copyright:: 2021 Firezone
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

# The enterprise_pg resources use the CLI to create databases and users. Set
# these environment variables so the commands have the correct connection
# settings.

ENV['PGHOST'] = node['firezone']['database']['host']
ENV['PGPORT'] = node['firezone']['database']['port'].to_s
ENV['PGUSER'] = node['firezone']['database']['user']
ENV['PGPASSWORD'] = node['firezone']['database']['password']

enterprise_pg_user node['firezone']['database']['user'] do
  superuser true
  password node['firezone']['database']['password'] || ''
  # If the database user is the same as the main postgres user, don't create it.
  not_if do
    node['firezone']['database']['user'] ==
      node['firezone']['postgresql']['username']
  end
end

enterprise_pg_database node['firezone']['database']['name'] do
  owner node['firezone']['database']['user']
end

node['firezone']['database']['extensions'].each do |ext, _enable|
  execute "create postgresql #{ext} extension" do
    user node['firezone']['database']['user']
    command "echo 'CREATE EXTENSION IF NOT EXISTS #{ext}' | psql"
    not_if "echo '\\dx' | psql #{node['firezone']['database']['name']} | grep #{ext}"
  end
end
