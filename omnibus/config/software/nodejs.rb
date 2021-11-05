name "nodejs"
description "NodeJS"
default_version "14.18.1"
license_file "LICENSE"

source url: "https://github.com/nodejs/node/archive/refs/tags/v#{version}.tar.gz"

version("16.6.2") do
  source sha256: "9b539b1ea5e3fbd173fcbaae97088401b228c36c2076c98d04c73802713bbb73"
end
version("14.18.1") do
  source sha256: "ee873d13ce00680c682be27132a420b3b5620f17549906dda7e2398b56ba41b0"
end

dependency "python"

relative_path "node-#{version}"

build do
  env = with_standard_compiler_flags(with_embedded_path)

  command "./configure --prefix=#{install_dir}/embedded", env: env
  make "-j #{workers}", env: env
  make "-j #{workers} install", env: env
end
