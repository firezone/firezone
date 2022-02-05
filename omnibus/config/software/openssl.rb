# frozen_string_literal: true

#
# Copyright:: Chef Software Inc.
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

name 'openssl'

license 'OpenSSL'
license_file 'LICENSE'
skip_transitive_dependency_licensing true

dependency 'cacerts'
dependency 'openssl-fips' if fips_mode?

default_version '1.1.1k' # do_not_auto_update

# Openssl builds engines as libraries into a special directory. We need to include
# that directory in lib_dirs so omnibus can sign them during macOS deep signing.
lib_dirs lib_dirs.concat(["#{install_dir}/embedded/lib/engines"])
lib_dirs lib_dirs.concat(["#{install_dir}/embedded/lib/engines-1.1"]) if version.start_with?('1.1')

# OpenSSL source ships with broken symlinks which windows doesn't allow.
# So skip error checking with `extract: :lax_tar`
if version.satisfies?('> 1.0.2u') && version.satisfies?('< 1.1.0')
  # 1.0.2u was the last public release of 1.0.2. Subsequent releases come from a support contract with OpenSSL Software Services
  source url: "https://s3.amazonaws.com/chef-releng/openssl/openssl-#{version}.tar.gz", extract: :lax_tar
else
  # As of 2020-09-09 even openssl-1.0.0.tar.gz can be downloaded from /source/openssl-VERSION.tar.gz
  # However, the latest releases are not in /source/old/VERSION/openssl-VERSION.tar.gz.
  # Let's stick with the simpler one for now.
  source url: "https://www.openssl.org/source/openssl-#{version}.tar.gz", extract: :lax_tar
end

version('1.1.1k') { source sha256: '892a0875b9872acd04a9fde79b1f943075d5ea162415de3047c327df33fbaee5' }
version('1.1.1j') { source sha256: 'aaf2fcb575cdf6491b98ab4829abf78a3dec8402b8b81efc8f23c00d443981bf' }
version('1.1.1i') { source sha256: 'e8be6a35fe41d10603c3cc635e93289ed00bf34b79671a3a4de64fcee00d5242' }

version('1.0.2y') { source sha256: '4882ec99f8e147ab26375da8a6af92efae69b6aef505234764f8cd00a1b81ffc' }
version('1.0.2x') { source sha256: '79cb4e20004a0d1301210aee7e154ddfba3d6a33d0df1f6c5d3257cb915a59c9' }
version('1.0.2w') { source sha256: 'a675ad1a9df59015cebcdf713de76a422347c5d99f11232fe75758143defd680' }
version('1.0.2i') { source sha256: '9287487d11c9545b6efb287cdb70535d4e9b284dd10d51441d9b9963d000de6f' }

relative_path "openssl-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)
  if aix?
    env['M4'] = '/opt/freeware/bin/m4'
  elsif mac_os_x? && arm?
    env['CFLAGS'] << ' -Qunused-arguments'
  elsif freebsd?
    # Should this just be in standard_compiler_flags?
    env['LDFLAGS'] += " -Wl,-rpath,#{install_dir}/embedded/lib"
  elsif windows?
    # XXX: OpenSSL explicitly sets -march=i486 and expects that to be honored.
    # It has OPENSSL_IA32_SSE2 controlling whether it emits optimized SSE2 code
    # and the 32-bit calling convention involving XMM registers is...  vague.
    # Do not enable SSE2 generally because the hand optimized assembly will
    # overwrite registers that mingw expects to get preserved.
    env['CFLAGS'] = "-I#{install_dir}/embedded/include"
    env['CPPFLAGS'] = env['CFLAGS']
    env['CXXFLAGS'] = env['CFLAGS']
  end

  configure_args = [
    "--prefix=#{install_dir}/embedded",
    'no-unit-test',
    'no-comp',
    'no-idea',
    'no-mdc2',
    'no-rc5',
    'no-ssl2',
    'no-ssl3',
    'no-zlib',
    'shared'
  ]

  configure_args += ["--with-fipsdir=#{install_dir}/embedded", 'fips'] if fips_mode?

  configure_cmd =
    if aix?
      'perl ./Configure aix64-cc'
    elsif mac_os_x?
      intel? ? './Configure darwin64-x86_64-cc' : './Configure darwin64-arm64-cc no-asm'
    elsif smartos?
      '/bin/bash ./Configure solaris64-x86_64-gcc -static-libgcc'
    elsif omnios?
      '/bin/bash ./Configure solaris-x86-gcc'
    elsif solaris2?
      platform = sparc? ? 'solaris64-sparcv9-gcc' : 'solaris64-x86_64-gcc'
      if version.satisfies?('< 1.1.0')
        "/bin/bash ./Configure #{platform} -static-libgcc"
      else
        "./Configure #{platform} -static-libgcc"
      end
    elsif windows?
      platform = windows_arch_i386? ? 'mingw' : 'mingw64'
      "perl.exe ./Configure #{platform}"
    else
      prefix =
        if linux? && ppc64?
          './Configure linux-ppc64'
        elsif linux? && s390x?
          # With gcc > 4.3 on s390x there is an error building
          # with inline asm enabled
          './Configure linux64-s390x -DOPENSSL_NO_INLINE_ASM'
        else
          './config'
        end
      "#{prefix} disable-gost"
    end

  patch_env = if aix?
                # This enables omnibus to use 'makedepend'
                # from fileset 'X11.adt.imake' (AIX install media)
                env['PATH'] = "/usr/lpp/X11/bin:#{ENV['PATH']}"
                penv = env.dup
                penv['PATH'] = "/opt/freeware/bin:#{env['PATH']}"
                penv
              else
                env
              end

  if version.start_with? '1.0'
    patch source: 'openssl-1.0.1f-do-not-build-docs.patch', env: patch_env
  elsif version.start_with? '1.1'
    patch source: 'openssl-1.1.0f-do-not-install-docs.patch', env: patch_env
  end

  patch source: 'openssl-1.0.2x-darwin-arm64.patch' if version.start_with?('1.0.2') && mac_os_x? && arm?

  if version.start_with?('1.0.2') && windows?
    # Patch Makefile.org to update the compiler flags/options table for mingw.
    patch source: 'openssl-1.0.1q-fix-compiler-flags-table-for-msys.patch', env: env
  end

  # Out of abundance of caution, we put the feature flags first and then
  # the crazy platform specific compiler flags at the end.
  configure_args << env['CFLAGS'] << env['LDFLAGS']

  configure_command = configure_args.unshift(configure_cmd).join(' ')

  command configure_command, env: env, in_msys_bash: true

  patch source: 'openssl-1.0.1j-windows-relocate-dll.patch', env: env if version.start_with?('1.0.2') && windows?

  make 'depend', env: env
  # make -j N on openssl is not reliable
  make "-j #{workers}", env: env
  if aix?
    # We have to sudo this because you can't actually run slibclean without being root.
    # Something in openssl changed in the build process so now it loads the libcrypto
    # and libssl libraries into AIX's shared library space during the first part of the
    # compile. This means we need to clear the space since it's not being used and we
    # can't install the library that is already in use. Ideally we would patch openssl
    # to make this not be an issue.
    # Bug Ref: http://rt.openssl.org/Ticket/Display.html?id=2986&user=guest&pass=guest
    command 'sudo /usr/sbin/slibclean', env: env
  end
  make "-j #{workers} install", env: env
end
