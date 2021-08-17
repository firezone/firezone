#
# Copyright 2013-2018 Chef Software, Inc.
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
# Install bzip2 and its shared library, libbz2.so
# This library object is required for building Python with the bz2 module,
# and should be picked up automatically when building Python.

name "bzip2"
default_version "1.0.8"

license "BSD-2-Clause"
license_file "LICENSE"
skip_transitive_dependency_licensing true

dependency "zlib"
dependency "openssl"

# version_list: url=https://sourceware.org/pub/bzip2/ filter=*.tar.gz
version("1.0.8") { source sha256: "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269" }

source url: "https://fossies.org/linux/misc/#{name}-#{version}.tar.gz"

relative_path "#{name}-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  # Avoid warning where .rodata cannot be used when making a shared object
  env["CFLAGS"] << " -fPIC" unless aix?

  # The list of arguments to pass to make
  args = "PREFIX='#{install_dir}/embedded' VERSION='#{version}'"
  args << " CFLAGS='-qpic=small -qpic=large -O2 -g -D_ALL_SOURCE -D_LARGE_FILES'" if aix?

  patch source: "makefile_take_env_vars.patch", plevel: 1, env: env
  patch source: "makefile_no_bins.patch", plevel: 1, env: env # removes various binaries we don't want to ship
  patch source: "soname_install_dir.patch", env: env if mac_os_x?
  patch source: "aix_makefile.patch", env: env if aix?

  make "#{args} -j #{workers}", env: env
  make "#{args} -j #{workers} -f Makefile-libbz2_so", env: env
  make "#{args} -j #{workers} install", env: env
end
