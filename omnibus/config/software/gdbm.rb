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

name "gdbm"
default_version "1.21"

version("1.21")  { source sha256: "b0b7dbdefd798de7ddccdd8edf6693a30494f7789777838042991ef107339cc2" }

source url: "https://mirrors.kernel.org/gnu/gdbm/gdbm-#{version}.tar.gz"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  configure_command = %W(
    ./configure
    --prefix=#{install_dir}/embedded
  )

  command configure_command.join(" "), env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
