#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  # Development
  require "omnibus"
rescue LoadError
  # Production
  print ENV.fetch("VERSION", "0.0.0")
else
  Omnibus::Config.append_timestamp false
  print Omnibus::BuildVersion.semver
end
