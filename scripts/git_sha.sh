#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  # Development
  require "omnibus"
rescue LoadError
  # Production
  print ENV.fetch("GIT_SHA", "deadbeef")
else
  Omnibus::Config.append_timestamp false
  print Omnibus::BuildVersion.git_describe.split(".").last
end
