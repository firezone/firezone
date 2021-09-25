# frozen_string_literal: true

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

name "gawk"

default_version "5.1.0"

version("5.1.0") { source sha256: "03a0360edcd84bec156fe211bbc4fc8c78790973ce4e8b990a11d778d40b1a26" }

source url: "https://mirrors.kernel.org/gnu/gawk/gawk-#{version}.tar.gz"

relative_path "gawk-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  configure_command = ["./configure",
                       "--disable-mpfr",
                       "--prefix=#{install_dir}/embedded"]

  command configure_command.join(" "), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
