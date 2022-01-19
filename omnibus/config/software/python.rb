# frozen_string_literal: true

# Copyright:: Chef Software, Inc.
# Copyright:: Firezone
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

name "python"
description "Python"
default_version "3.9.7"
license_file "LICENSE"
skip_transitive_dependency_licensing true

source url: "https://www.python.org/ftp/python/#{version}/Python-#{version}.tgz"

version("3.9.6") { source sha256: "d0a35182e19e416fc8eae25a3dcd4d02d4997333e4ad1f2eee6010aadc3fe866" }
version("3.9.7") { source sha256: "a838d3f9360d157040142b715db34f0218e535333696a5569dc6f854604eb9d1" }
version("3.10.0") { source sha256: "c4e0cbad57c90690cb813fb4663ef670b4d0f587d8171e2c42bd4c9245bd2758" }

dependency "bzip2"
dependency "zlib"
dependency "openssl"
dependency "ncurses"
dependency "libffi"
dependency "libedit"

relative_path "Python-#{version}"

build do
  # Disables nis and dbm -- both cause build issues
  patch source: 'disable_modules.patch', target: 'Modules/Setup'
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
