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

name "firezone"
maintainer "FireZone"
homepage "https://firez.one"
license "Apache-2.0"
license_file "../LICENSE"

description <<~DESC
  Web UI + Firewall manager for WireGuard™
DESC

# Defaults to C:/firezone on Windows
# and /opt/firezone on all other platforms
install_dir "#{default_root}/#{name}"

build_version Omnibus::BuildVersion.semver
build_iteration 1

# firezone build dependencies/components
dependency "compile_release"
dependency "erlang"
dependency "elixir"
dependency "openssl"
dependency "postgresql"
dependency "wireguard-tools"

if linux?
  dependency "nftables"
end

exclude ".env"
exclude ".github"
exclude ".vagrant"
exclude ".ci"
exclude "**/.git"
exclude "**/bundler/git"
