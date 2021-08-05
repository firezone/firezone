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
dependency "nodejs"

source path: File.expand_path("../", Omnibus::Config.project_root)

license :project_license
skip_transitive_dependency_licensing true

build do
  command "mix local.hex --force"
  command "mix local.rebar --force"
  command "mix deps.get --only prod"
  command "mix deps.compile --only prod"
  command "npm ci --prefix apps/fz_http/assets --progress=false --no-audit --loglevel=error"
  command "npm run --prefix apps/fz_http/assets deploy"
  command "cd apps/fz_http && mix phx.digest", env: { "MIX_ENV": "prod" }
  command "mix release", env: { "MIX_ENV": "prod" }
  move "_build/prod/rel/firezone", "#{install_dir}/embedded/firezone"
end
