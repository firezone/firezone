name "nodejs"
description "NodeJS"
default_version "16.6.2"
license_file "LICENSE"

source url: "https://github.com/nodejs/node/archive/refs/tags/v#{version}.tar.gz"

version("16.6.2") do
  source sha256: "9b539b1ea5e3fbd173fcbaae97088401b228c36c2076c98d04c73802713bbb73"
end

dependency "python"

relative_path "node-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
