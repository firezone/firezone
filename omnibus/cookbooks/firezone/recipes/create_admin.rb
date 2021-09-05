# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: create_admin
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

execute 'create_admin' do
  command 'bin/firezone rpc "FzHttp.Release.create_admin_user"'
  cwd node['firezone']['app_directory']
  environment(Firezone::Config.app_env(node['firezone']))
  user node['firezone']['user']
end

log 'admin_created' do
  msg = <<~MSG
    =================================================================================

    FireZone user created! Save this information because it will NOT be shown again.

    Use this to log into the Web UI.

    Email: #{node['firezone']['admin_email']}
    Password: #{node['firezone']['default_admin_password']}

    =================================================================================
  MSG

  message msg
  level :info # info and below are not shown by default
end
