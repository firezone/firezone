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
maintainer 'Firezone'
homepage 'https://firezone.dev'
license 'Apache-2.0'
license_file '../LICENSE'

description <<~DESC
  Web UI + Firewall manager for WireGuard
DESC

# Defaults to C:/firezone on Windows
# and /opt/firezone on all other platforms
install_dir "#{default_root}/#{name}"

# Prevent runner tmp dir from filling up
stage_path = '/opt/runner/omnibus-local/stage'
ENV['CI'] && Dir.exist?(stage_path) && staging_dir(stage_path)

# Use Release Drafter's resolved version
build_version ENV.fetch('VERSION', '0.0.0+git.0.ci')
build_iteration 1

# firezone build dependencies/components
dependency 'runit'
dependency 'nginx'
dependency 'erlang'
dependency 'elixir'
dependency 'openssl'
dependency 'postgresql'
dependency 'firezone'
dependency 'firezone-ctl'
dependency 'firezone-scripts'
dependency 'firezone-cookbooks'

# XXX: Ensure all development resources aren't included
exclude '.env'
exclude '.devcontainer'
exclude '.github'
exclude '.vagrant'
exclude '.ci'
exclude '**/.git'
exclude '**/bundler/git'
