# frozen_string_literal: true

# Copyright 2012-2014 FireZone
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

name "linenoise"
description "A small self-contained alternative to readline and libedit"

license_file "LICENSE"
skip_transitive_dependency_licensing true

source github: "antirez/linenoise"
default_version "master"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  cc = env.fetch("CC", "gcc")

  command "#{cc} -c linenoise.c -o linenoise.o -fPIC", env: env
  command "#{cc} -shared -o liblinenoise.so linenoise.o -lm", env: env

  copy "liblinenoise.so", "#{install_dir}/embedded/lib/"
  copy "linenoise.h", "#{install_dir}/embedded/include/"
end
