# frozen_string_literal: true

# Copyright 2021 FireZone
#
# All Rights Reserved.
#

name "firezone"
maintainer "FireZone"
homepage "https://firez.one"

# Defaults to C:/firezone on Windows
# and /opt/firezone on all other platforms
install_dir "#{default_root}/#{name}"

build_version Omnibus::BuildVersion.semver
build_iteration 1

# Creates required build directories
dependency "preparation"

# firezone dependencies/components
dependency "postgresql"
dependency "erlang"
dependency "elixir"
dependency "openssl"

exclude "**/.git"
exclude "**/bundler/git"
