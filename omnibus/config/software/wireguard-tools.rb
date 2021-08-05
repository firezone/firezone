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

default_src_url = "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-#{version}.zip"

version "1.0.20210424" do
  source url: default_src_url, sha256: "1ad170ded2d66d7c5a02fc2fd5ac3e195ec1c98133986f2d8223ed5a72c8877f"
end

build do
  env = with_standard_compiler_flags(with_embedded_path)

  make "-j #{workers}", env: env
  make "install", env: env
end
