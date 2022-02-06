# frozen_string_literal: true

# Copyright:: Firezone, Inc.
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

name 'readline'

default_version '8.1'

version('8.1') { source sha256: 'f8ceb4ee131e3232226a17f51b164afc46cd0b9e6cef344be87c65962cb82b02' }

source url: "https://mirrors.kernel.org/gnu/readline/readline-#{version}.tar.gz"

dependency 'config_guess'

relative_path "readline-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  update_config_guess
  configure_command = ['./configure',
                       '--disable-mpfr',
                       "--prefix=#{install_dir}/embedded"]

  command configure_command.join(' '), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
