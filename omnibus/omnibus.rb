# frozen_string_literal: true

# This file is used to configure the firezone project. It contains
# some minimal configuration examples for working with Omnibus. For a full list
# of configurable options, please see the documentation for +omnibus/config.rb+.
#

# Build internally
# ------------------------------
# By default, Omnibus uses system folders (like +/var+ and +/opt+) to build and
# cache components. If you would to build everything internally, you can
# uncomment the following options. This will prevent the need for root
# permissions in most cases.
#
# Uncomment this line to change the default base directory to "local"
# -------------------------------------------------------------------
base_dir("/tmp/omnibus-local")
#
# Alternatively you can tune the individual values
# ------------------------------------------------
# cache_dir     './local/omnibus/cache'
# git_cache_dir './local/omnibus/cache/git_cache'
# source_dir    './local/omnibus/src'
# build_dir     './local/omnibus/build'
# package_dir   './local/omnibus/pkg'
# package_tmp   './local/omnibus/pkg-tmp'

# Disable git caching
# ------------------------------
# use_git_caching false

# Enable S3 asset caching
# ------------------------------
# use_s3_caching true
# s3_access_key    ENV['AWS_ACCESS_KEY_ID']
# s3_secret_key    ENV['AWS_SECRET_ACCESS_KEY']
# s3_profile       ENV['AWS_S3_PROFILE']
# s3_iam_role_arn  ENV['S3_IAM_ROLE_ARN']
# s3_bucket        ENV['AWS_S3_BUCKET']

# Customize compiler bits
# ------------------------------
# solaris_compiler 'gcc'
# build_retries 5
# fetcher_read_timeout 120
# fetcher_retries 5

# Load additional software
# ------------------------------
# software_gems ['omnibus-software', 'my-company-software']
# local_software_dirs ['/path/to/local/software']

# Windows architecture defaults
# ------------------------------
windows_arch   %w[x86 x64].include?((ENV["OMNIBUS_WINDOWS_ARCH"] || "").downcase) ?
                 ENV["OMNIBUS_WINDOWS_ARCH"].downcase.to_sym : :x86
