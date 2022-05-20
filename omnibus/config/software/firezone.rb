# frozen_string_literal: true

# Copyright 2021 Firezone
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

name 'firezone'
description 'the steps required to compile the firezone elixir application'
default_version '1.0.0'

dependency 'postgresql'
dependency 'nodejs'
dependency 'elixir'
dependency 'nftables' if linux?
dependency 'ruby'

version('1.0.0') do
  source path: File.expand_path('../', Omnibus::Config.project_root),
         options: { exclude: [
           '.env',
           '.git',
           '.ci',
           '.vagrant',
           '.github',
           '_build',
           'deps',
           'omnibus',
           'apps/fz_http/assets/node_modules'
         ] }
end

license :project_license
skip_transitive_dependency_licensing true

build do
  env = with_standard_compiler_flags(with_embedded_path).merge(
    'MIX_ENV' => 'prod',
    'VERSION' => ENV.fetch('VERSION', Omnibus::BuildVersion.semver)
  )

  command 'mix local.hex --force', env: env
  command 'mix local.rebar --force', env: env
  command 'mix deps.get --only prod', env: env
  command 'mix deps.compile --only prod', env: env
  command 'npm ci --prefix apps/fz_http/assets --progress=false --no-audit --loglevel=error', env: env
  command 'npm run --prefix apps/fz_http/assets deploy', env: env
  command 'cd apps/fz_http && mix phx.digest', env: env
  command 'mix release', env: env
  sync '_build/prod/rel/firezone', "#{install_dir}/embedded/service/firezone"
end
