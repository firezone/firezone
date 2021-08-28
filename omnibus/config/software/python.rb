name "python"
description "Python"
default_version "3.9.6"
license_file "LICENSE"
skip_transitive_dependency_licensing true

source url: "https://www.python.org/ftp/python/#{version}/Python-#{version}.tgz"

version("3.9.6") do
  source sha256: "d0a35182e19e416fc8eae25a3dcd4d02d4997333e4ad1f2eee6010aadc3fe866"
end

dependency "bzip2"
dependency "zlib"
dependency "openssl"
dependency "ncurses"
dependency "libffi"

relative_path "Python-#{version}"

build do
  patch source: 'disable_nis.patch', target: 'Modules/Setup'
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
