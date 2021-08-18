#
# Copyright 2012-2016 Chef Software, Inc.
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

name 'ruby'
license 'BSD-2-Clause'
license_file 'BSDL'
license_file 'COPYING'
license_file 'LEGAL'

skip_transitive_dependency_licensing true

# - chef-client cannot use 2.2.x yet due to a bug in IRB that affects chef-shell on linux:
#   https://bugs.ruby-lang.org/issues/11869
# - the current status of 2.3.x is that it downloads but fails to compile.
# - verify that all ffi libs are available for your version on all platforms.
# - when upgrading please check the ABI version and update the exclusion until
#   https://gitlab.com/gitlab-org/omnibus-gitlab/issues/3414 is addressed
default_version '2.7.4'

fips_enabled = (project.overrides[:fips] && project.overrides[:fips][:enabled]) || false

dependency 'patch' if (solaris? && platform_version.satisfies?("10"))
dependency 'ncurses' unless windows? || version.satisfies?('>= 2.1')
dependency 'zlib'
dependency 'openssl'
dependency 'libffi'
dependency 'libyaml'
# Needed for chef_gem installs of (e.g.) nokogiri on upgrades -
# they expect to see our libiconv instead of a system version.
# Ignore on windows - TDM GCC comes with libiconv in the runtime
# and that's the only one we will ever use.
dependency 'libiconv'

version('2.7.4') { source sha256: '3043099089608859fc8cce7f9fdccaa1f53a462457e3838ec3b25a7d609fbc5b' }
version('2.7.3') { source sha256: '8925a95e31d8f2c81749025a52a544ea1d05dad18794e6828709268b92e55338' }
version('2.7.2') { source sha256: '6e5706d0d4ee4e1e2f883db9d768586b4d06567debea353c796ec45e8321c3d4' }

source url: "https://cache.ruby-lang.org/pub/ruby/#{version.match(/^(\d+\.\d+)/)[0]}/ruby-#{version}.tar.gz"

relative_path "ruby-#{version}"

env = with_standard_compiler_flags(with_embedded_path)

if mac_os_x?
  # -Qunused-arguments suppresses "argument unused during compilation"
  # warnings. These can be produced if you compile a program that doesn't
  # link to anything in a path given with -Lextra-libs. Normally these
  # would be harmless, except that autoconf treats any output to stderr as
  # a failure when it makes a test program to check your CFLAGS (regardless
  # of the actual exit code from the compiler).
  env['CFLAGS'] << " -I#{install_dir}/embedded/include/ncurses -arch x86_64 -m64 -O3 -g -pipe -Qunused-arguments"
  env['LDFLAGS'] << ' -arch x86_64'
elsif freebsd?
  # Stops "libtinfo.so.5.9: could not read symbols: Bad value" error when
  # compiling ext/readline. See the following for more info:
  #
  #   https://lists.freebsd.org/pipermail/freebsd-current/2013-October/045425.html
  #   http://mailing.freebsd.ports-bugs.narkive.com/kCgK8sNQ/ports-183106-patch-sysutils-libcdio-does-not-build-on-10-0-and-head
  #
  env['LDFLAGS'] << ' -ltinfow'
elsif aix?
  # this magic per IBM
  env['LDSHARED'] = 'xlc -G'
  env['CFLAGS'] = "-I#{install_dir}/embedded/include/ncurses -I#{install_dir}/embedded/include"
  # this magic per IBM
  env['XCFLAGS'] = '-DRUBY_EXPORT'
  # need CPPFLAGS set so ruby doesn't try to be too clever
  env['CPPFLAGS'] = "-I#{install_dir}/embedded/include/ncurses -I#{install_dir}/embedded/include"
  env['SOLIBS'] = '-lm -lc'
  # need to use GNU m4, default m4 doesn't work
  env['M4'] = '/opt/freeware/bin/m4'
elsif solaris? && platform_version.satisfies?("10")
  if sparc?
    # Known issue with rubby where too much GCC optimization blows up miniruby on sparc
    env['CFLAGS'] << ' -std=c99 -O0 -g -pipe -mcpu=v9'
    env['LDFLAGS'] << ' -mcpu=v9'
  else
    env['CFLAGS'] << ' -std=c99 -O3 -g -pipe'
  end
elsif windows?
  env['CPPFLAGS'] << ' -DFD_SETSIZE=2048'
else # including linux
  env['CFLAGS'] << if version.satisfies?('>= 2.3.0') &&
      rhel? && platform_version.satisfies?('< 6.0')
                     ' -O2 -g -pipe'
                   else
                     ' -O3 -g -pipe'
                   end
end

build do
  env['CFLAGS'] << ' -fno-omit-frame-pointer'

  # AIX needs /opt/freeware/bin only for patch
  patch_env = env.dup
  patch_env['PATH'] = "/opt/freeware/bin:#{env['PATH']}" if aix?

  if solaris? && platform_version.satisfies?("10") && version.satisfies?('>= 2.1')
    patch source: 'ruby-no-stack-protector.patch', plevel: 1, env: patch_env
  elsif solaris? && platform_version.satisfies?("10") && version =~ /^1.9/
    patch source: 'ruby-sparc-1.9.3-c99.patch', plevel: 1, env: patch_env
  elsif solaris? && platform_version.satisfies?("11") && version =~ /^2.1/
    patch source: 'ruby-solaris-linux-socket-compat.patch', plevel: 1, env: patch_env
  end

  # wrlinux7/ios_xr build boxes from Cisco include libssp and there is no way to
  # disable ruby from linking against it, but Cisco switches will not have the
  # library.  Disabling it as we do for Solaris.
  # TODO: Failing with "undefined method "ios_xr?". Not supporting Cisco switches yet.
  # patch source: 'ruby-no-stack-protector.patch', plevel: 1, env: patch_env if ios_xr? && version.satisfies?('>= 2.1')

  # disable libpath in mkmf across all platforms, it trolls omnibus and
  # breaks the postgresql cookbook.  i'm not sure why ruby authors decided
  # this was a good idea, but it breaks our use case hard.  AIX cannot even
  # compile without removing it, and it breaks some native gem installs on
  # other platforms.  generally you need to have a condition where the
  # embedded and non-embedded libs get into a fight (libiconv, openssl, etc)
  # and ruby trying to set LD_LIBRARY_PATH itself gets it wrong.
  #
  # Also, fix paths emitted in the makefile on windows on both msys and msys2.
  if version.satisfies?('>= 2.1')
    patch source: 'ruby-mkmf.patch', plevel: 1, env: patch_env
    # should intentionally break and fail to apply on 2.2, patch will need to
    # be fixed.
  end

  # Enable custom patch created by ayufan that allows to count memory allocations
  # per-thread. This is asked to be upstreamed as part of https://github.com/ruby/ruby/pull/3978
  patch source: 'thread-memory-allocations-2.7.patch', plevel: 1, env: patch_env

  # Fix reserve stack segmentation fault when building on RHEL5 or below
  # Currently only affects 2.1.7 and 2.2.3. This patch taken from the fix
  # in Ruby trunk and expected to be included in future point releases.
  # https://redmine.ruby-lang.org/issues/11602
  if rhel? &&
      platform_version.satisfies?('< 6') &&
      (version == '2.1.7' || version == '2.2.3')

    patch source: 'ruby-fix-reserve-stack-segfault.patch', plevel: 1, env: patch_env
  end

  # copy_file_range() has been disabled on recent RedHat kernels:
  # 1. https://gitlab.com/gitlab-org/gitlab/-/issues/218999
  # 2. https://bugs.ruby-lang.org/issues/16965
  # 3. https://bugzilla.redhat.com/show_bug.cgi?id=1783554
  patch source: 'ruby-disable-copy-file-range.patch', plevel: 1, env: patch_env if centos? || rhel?

  configure_command = ['--with-out-ext=dbm,readline',
                       '--enable-shared',
                       '--disable-install-doc',
                       '--without-gmp',
                       '--without-gdbm',
                       '--without-tk',
                       '--disable-dtrace']
  configure_command << '--with-ext=psych' if version.satisfies?('< 2.3')
  configure_command << '--with-bundled-md5' if fips_enabled

  if aix?
    # need to patch ruby's configure file so it knows how to find shared libraries
    patch source: 'ruby-aix-configure.patch', plevel: 1, env: patch_env
    # have ruby use zlib on AIX correctly
    patch source: 'ruby_aix_openssl.patch', plevel: 1, env: patch_env
    # AIX has issues with ssl retries, need to patch to have it retry
    patch source: 'ruby_aix_2_1_3_ssl_EAGAIN.patch', plevel: 1, env: patch_env
    # the next two patches are because xlc doesn't deal with long vs int types well
    patch source: 'ruby-aix-atomic.patch', plevel: 1, env: patch_env
    patch source: 'ruby-aix-vm-core.patch', plevel: 1, env: patch_env

    # per IBM, just help ruby along on what it's running on
    configure_command << '--host=powerpc-ibm-aix6.1.0.0 --target=powerpc-ibm-aix6.1.0.0 --build=powerpc-ibm-aix6.1.0.0 --enable-pthread'

  elsif freebsd?
    # Disable optional support C level backtrace support. This requires the
    # optional devel/libexecinfo port to be installed.
    configure_command << 'ac_cv_header_execinfo_h=no'
    configure_command << "--with-opt-dir=#{install_dir}/embedded"
  elsif smartos?
    # Opscode patch - someara@opscode.com
    # GCC 4.7.0 chokes on mismatched function types between OpenSSL 1.0.1c and Ruby 1.9.3-p286
    patch source: 'ruby-openssl-1.0.1c.patch', plevel: 1, env: patch_env

    # Patches taken from RVM.
    # http://bugs.ruby-lang.org/issues/5384
    # https://www.illumos.org/issues/1587
    # https://github.com/wayneeseguin/rvm/issues/719
    patch source: 'rvm-cflags.patch', plevel: 1, env: patch_env

    # From RVM forum
    # https://github.com/wayneeseguin/rvm/commit/86766534fcc26f4582f23842a4d3789707ce6b96
    configure_command << 'ac_cv_func_dl_iterate_phdr=no'
    configure_command << "--with-opt-dir=#{install_dir}/embedded"
  elsif windows?
    configure_command << ' debugflags=-g'
  else
    # TODO: Consider pulling in Gitlab's OhaiHelper if raspberry_pi is needed
    # configure_command << %w(host target build).map { |w| "--#{w}=#{OhaiHelper.gcc_target}" } if OhaiHelper.raspberry_pi?
    configure_command << "--with-opt-dir=#{install_dir}/embedded"
  end

  # FFS: works around a bug that infects AIX when it picks up our pkg-config
  # AFAIK, ruby does not need or use this pkg-config it just causes the build to fail.
  # The alternative would be to patch configure to remove all the pkg-config garbage entirely
  env['PKG_CONFIG'] = '/bin/true' if aix?

  configure(*configure_command, env: env)
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env

  if windows?
    # Needed now that we switched to msys2 and have not figured out how to tell
    # it how to statically link yet
    dlls = ['libwinpthread-1']
    dlls << if windows_arch_i386?
              'libgcc_s_dw2-1'
            else
              'libgcc_s_seh-1'
            end
    dlls.each do |dll|
      arch_suffix = windows_arch_i386? ? '32' : '64'
      windows_path = "C:/msys2/mingw#{arch_suffix}/bin/#{dll}.dll"
      raise "Cannot find required DLL needed for dynamic linking: #{windows_path}" unless File.exist?(windows_path)

      copy windows_path, "#{install_dir}/embedded/bin/#{dll}.dll"
    end
  end
end
