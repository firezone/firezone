# frozen_string_literal: true

# Copyright:: Chef Software, Inc.
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

name "postgresql"
default_version "13.3"

license "PostgreSQL"
license_file "COPYRIGHT"
skip_transitive_dependency_licensing true

dependency "autoconf"
dependency "automake"
dependency "m4"
dependency "pkg-config"
dependency "zlib"
dependency "openssl"
dependency "libedit"
dependency "libossp-uuid"
dependency "ncurses"
dependency "config_guess"

# version_list: url=https://ftp.postgresql.org/pub/source/v#{version}/ filter=*.tar.bz2

version("13.3")   { source sha256: "3cd9454fa8c7a6255b6743b767700925ead1b9ab0d7a0f9dcb1151010f8eb4a1" }

# Version 12.x will EoL November 14, 2024
version("12.7")   { source sha256: "8490741f47c88edc8b6624af009ce19fda4dc9b31c4469ce2551d84075d5d995" }

# Version 9.6 will EoL November 11, 2021
version("9.6.22") { source sha256: "3d32cd101025a0556813397c69feff3df3d63736adb8adeaf365c522f39f2930" }

# Version 9.3 was EoL November 8, 2018 (but used in Supermarket as of 6.2021)
version("9.3.25") { source sha256: "e4953e80415d039ccd33d34be74526a090fd585cf93f296cd9c593972504b6db" }

source url: "https://ftp.postgresql.org/pub/source/v#{version}/postgresql-#{version}.tar.bz2"

relative_path "postgresql-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  update_config_guess(target: "config")

  configure_command = [
    "./configure",
    "--prefix=#{install_dir}/embedded",
    "--with-libedit-preferred",
    "--with-openssl",
    "--enable-thread-safety",
    "--with-includes=#{install_dir}/embedded/include",
    "--with-libraries=#{install_dir}/embedded/lib"
  ]

  if linux?
    configure_command << "--with-uuid=ossp"
  elsif mac_os_x?
    configure_command << "--with-uuid=e2fs"
  end

  command configure_command.join(" "), env: env
  make "world -j #{workers}", env: env
  make "install-world", env: env
end
