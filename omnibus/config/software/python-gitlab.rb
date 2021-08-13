#
# Copyright:: Copyright (c) 2013-2014 Chef Software, Inc.
# Copyright:: Copyright (c) 2016-2020 GitLab B.V.
# License:: Apache License, Version 2.0
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

name 'python3'
# If bumping from 3.7.x to something higher, be sure to update the following files with the new path:
# config/software/python-docutils.rb
# files/gitlab-cookbooks/gitaly/recipes/enable.rb
# files/gitlab-cookbooks/gitlab/attributes/default.rb
# spec/chef/recipes/gitaly_spec.rb
# spec/chef/recipes/gitlab-rails_spec.rb
default_version '3.7.10'

dependency 'libedit'
dependency 'ncurses'
dependency 'zlib'
dependency 'openssl'
dependency 'bzip2'
dependency 'libffi'
dependency 'liblzma'
dependency 'libyaml'

license 'Python-2.0'
license_file 'LICENSE'

skip_transitive_dependency_licensing true

source url: "https://www.python.org/ftp/python/#{version}/Python-#{version}.tgz",
       sha256: 'c9649ad84dc3a434c8637df6963100b2e5608697f9ba56d82e3809e4148e0975'

relative_path "Python-#{version}"

LIB_PATH = %W(#{install_dir}/embedded/lib #{install_dir}/embedded/lib64 #{install_dir}/lib #{install_dir}/lib64 #{install_dir}/libexec).freeze

env = {
  'CFLAGS' => "-I#{install_dir}/embedded/include -O3 -g -pipe",
  'LDFLAGS' => "-Wl,-rpath,#{LIB_PATH.join(',-rpath,')} -L#{LIB_PATH.join(' -L')} -I#{install_dir}/embedded/include"
}

build do
  # Patches below are based on patches provided by martin.panter, 2016-06-02 06:31
  # in https://bugs.python.org/issue13501
  patch source: 'configure.patch', target: "configure"
  patch source: 'pyconfig.h.in.patch', target: "pyconfig.h.in"
  patch source: 'readline.c.patch', target: "Modules/readline.c"
  patch source: 'setup.py.patch', target: "setup.py"

  command ['./configure',
           "--prefix=#{install_dir}/embedded",
           '--enable-shared',
           '--with-readline=editline',
           '--with-dbmliborder='].join(' '), env: env
  make env: env
  make 'install', env: env

  delete("#{install_dir}/embedded/lib/python3.7/lib-dynload/dbm.*")
  delete("#{install_dir}/embedded/lib/python3.7/lib-dynload/_sqlite3.*")
  delete("#{install_dir}/embedded/lib/python3.7/test")
  command "find #{install_dir}/embedded/lib/python3.7 -name '__pycache__' -type d -print -exec rm -r {} +"
end

project.exclude "embedded/bin/python3*-config"
