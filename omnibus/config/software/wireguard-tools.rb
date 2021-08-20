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

name "wireguard-tools"
description "wireguard userspace utilities"
default_version "1.0.20210424"

default_src_url = "https://github.com/WireGuard/wireguard-tools/archive/refs/tags/v#{version}.tar.gz"

version "1.0.20210424" do
  source url: default_src_url, sha256: "6b32b5deba067b9a920f008a006f001fa1ec903dc69fcaa5674b5a043146c1f7"
end

relative_path "wireguard-tools-#{version}/src"
license "GPL-2.0"

build do
  env = with_standard_compiler_flags(with_embedded_path).merge(
    "PREFIX" => "#{install_dir}/embedded"
  )

  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
