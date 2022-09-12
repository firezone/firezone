# frozen_string_literal: true

# Copyright 2017 Chef Software, Inc.
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
# expeditor/ignore: deprecated 2021-04

name 'elixir'
default_version '1.14.0'

license 'Apache-2.0'
license_file 'LICENSE'

dependency 'erlang'

version('1.4.2') { source sha256: 'cb4e2ec4d68b3c8b800179b7ae5779e2999aa3375f74bd188d7d6703497f553f' }
version('1.12.2') { source sha256: '701006d1279225fc42f15c8d3f39906db127ddcc95373d34d8d160993356b15c' }
version('1.12.3') { source sha256: 'c5affa97defafa1fd89c81656464d61da8f76ccfec2ea80c8a528decd5cb04ad' }
version('1.13.1') { source sha256: 'deaba8156b11777adfa28e54e76ddf49ab1a0132cca54c41d9d7648e800edcc8' }
version('1.13.2') { source sha256: '03afed42dccf4347c4d3ae2b905134093a3ba2245d0d3098d75009a1d659ed1a' }
version('1.13.4') { source sha256: '95daf2dd3052e6ca7d4d849457eaaba09de52d65ca38d6933c65bc1cdf6b8579' }
version('1.14.0') { source sha256: 'ac129e266a1e04cdc389551843ec3dbdf36086bb2174d3d7e7936e820735003b' }

source url: "https://github.com/elixir-lang/elixir/archive/v#{version}.tar.gz"
relative_path "elixir-#{version}"

build do
  env = with_standard_compiler_flags(
    'PATH' => "/opt/runner/local/bin:#{with_embedded_path['PATH']}"
  )

  make "-j #{workers}", env: env
  make "-j #{workers} install PREFIX=/opt/runner/local", env: env
end
