#
# Copyright 2017 Chef Software, Inc.
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
# expeditor/ignore: deprecated 2021-04

name "elixir"
default_version "1.12.2"

license "Apache-2.0"
license_file "LICENSE"

dependency "erlang"

version("1.4.2") { source sha256: "cb4e2ec4d68b3c8b800179b7ae5779e2999aa3375f74bd188d7d6703497f553f" }
version("1.12.2") { source sha256: "701006d1279225fc42f15c8d3f39906db127ddcc95373d34d8d160993356b15c" }
source url: "https://github.com/elixir-lang/elixir/archive/v#{version}.tar.gz"
relative_path "elixir-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  make env: env
  make "install PREFIX=#{install_dir}/embedded", env: env
end
