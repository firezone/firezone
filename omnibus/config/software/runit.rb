# frozen_string_literal: true

# Copyright 2012-2014 Chef Software, Inc.
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

name "runit"
default_version "2.1.2"

license "BSD-3-Clause"
license_file "../package/COPYING"

skip_transitive_dependency_licensing true

version "2.1.2" do
  source md5: "6c985fbfe3a34608eb3c53dc719172c4"
end

source url: "http://smarden.org/runit/runit-#{version}.tar.gz"

relative_path "admin/runit-#{version}/src"

build do
  # Patch runit to not consider status of log service associated with a service
  # on determining output of status command. For details, check
  # https://gitlab.com/gitlab-org/omnibus-gitlab/issues/4008
  patch source: "log-status.patch"

  env = with_standard_compiler_flags(with_embedded_path)

  # Put runit where we want it, not where they tell us to
  command 'sed -i -e "s/^char\ \*varservice\ \=\"\/service\/\";$/char\ \*varservice\ \=\"' + install_dir.gsub("/", '\\/') + '\/service\/\";/" sv.c',
          env: env

  # TODO: the following is not idempotent
  command "sed -i -e s:-static:: Makefile", env: env

  # Build it
  make "-j #{workers}", env: env
  make "-j #{workers} check", env: env

  # Move it
  mkdir "#{install_dir}/embedded/bin"
  copy "#{project_dir}/chpst",      "#{install_dir}/embedded/bin"
  copy "#{project_dir}/runit",      "#{install_dir}/embedded/bin"
  copy "#{project_dir}/runit-init", "#{install_dir}/embedded/bin"
  copy "#{project_dir}/runsv",      "#{install_dir}/embedded/bin"
  copy "#{project_dir}/runsvchdir", "#{install_dir}/embedded/bin"
  copy "#{project_dir}/runsvdir",   "#{install_dir}/embedded/bin"
  copy "#{project_dir}/sv",         "#{install_dir}/embedded/bin"
  copy "#{project_dir}/svlogd",     "#{install_dir}/embedded/bin"
  copy "#{project_dir}/utmpset",    "#{install_dir}/embedded/bin"

  erb source: "runsvdir-start.erb",
      dest: "#{install_dir}/embedded/bin/runsvdir-start",
      mode: 0o755,
      vars: { install_dir: install_dir }

  # Setup service directories
  touch "#{install_dir}/service/.gitkeep"
  touch "#{install_dir}/sv/.gitkeep"
  touch "#{install_dir}/init/.gitkeep"
end
