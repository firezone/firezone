# frozen_string_literal: true

#
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

name "perl"

license "Artistic-2.0"
license_file "Artistic"
skip_transitive_dependency_licensing true

default_version "5.34.0"

# versions_list: http://www.cpan.org/src/ filter=*.tar.gz
version("5.34.0") { source sha256: "551efc818b968b05216024fb0b727ef2ad4c100f8cb6b43fab615fa78ae5be9a" }
version("5.32.1") { source sha256: "03b693901cd8ae807231b1787798cf1f2e0b8a56218d07b7da44f784a7caeb2c" }
version("5.30.0") { source sha256: "851213c754d98ccff042caa40ba7a796b2cee88c5325f121be5cbb61bbf975f2" }
version("5.22.1") { source sha256: "2b475d0849d54c4250e9cba4241b7b7291cffb45dfd083b677ca7b5d38118f27" }
version("5.18.1") { source sha256: "655e11a8ffba8853efcdce568a142c232600ed120ac24aaebb4e6efe74e85b2b" }
source url: "http://www.cpan.org/src/5.0/perl-#{version}.tar.gz"

# perl builds perl as libraries into a special directory. We need to include
# that directory in lib_dirs so omnibus can sign them during macOS deep signing.
lib_dirs lib_dirs.concat ["#{install_dir}/embedded/lib/perl5/**"]

relative_path "perl-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  patch source: "perl-#{version}-remove_lnsl.patch", plevel: 1, env: env

  cc_command = if solaris2?
                 "-Dcc='gcc -m64 -static-libgcc'"
               elsif aix?
                 "-Dcc='/opt/IBM/xlc/13.1.0/bin/cc_r -q64'"
               elsif freebsd? && ohai["os_version"].to_i >= 1_000_024
                 "-Dcc='clang'"
               elsif mac_os_x?
                 "-Dcc='clang'"
               else
                 "-Dcc='gcc -static-libgcc'"
               end

  configure_command = ["sh Configure",
                       " -de",
                       " -Dprefix=#{install_dir}/embedded",
                       " -Duseshrplib",
                       " -Dusethreads",
                       " #{cc_command}",
                       " -Dnoextensions='DB_File GDBM_File NDBM_File ODBM_File'"]

  if aix?
    configure_command << "-Dmake=gmake"
    configure_command << "-Duse64bitall"
  end

  command configure_command.join(" "), env: env
  make "-j #{workers}", env: env
  # using the install.perl target lets
  # us skip install the manpages
  make "install.perl", env: env
end
