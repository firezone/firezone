# frozen_string_literal: true

# Copyright 2021 FireZone
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

name "compile_release"
description "the steps required to compile the firezone elixir application"
default_version "1.0.0"

dependency "elixir"

source path: File.expand_path("../", Omnibus::Config.project_root),
       options: { exclude: ["_build/", "deps/", "apps/fz_http/assets/node_modules/"] }

license :project_license
skip_transitive_dependency_licensing true

build do
  env = { "MIX_ENV": "prod" }.merge(with_standard_compiler_flags(with_embedded_path))

  command "mix local.hex --force", env: env
  command "mix local.rebar --force", env: env
  command "mix deps.get --only prod", env: env
  command "mix deps.compile --only prod", env: env
  command "npm ci --prefix apps/fz_http/assets --progress=false --no-audit --loglevel=error", env: env
  command "npm run --prefix apps/fz_http/assets deploy", env: env
  command "cd apps/fz_http && mix phx.digest", env: env
  command "mix release", env: env
  move "_build/prod/rel/firezone", "#{install_dir}/embedded/firezone"
end
