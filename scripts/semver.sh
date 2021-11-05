#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require "omnibus"
rescue LoadError
  print "0.0.0"
else
  Omnibus::Config.append_timestamp false
  print Omnibus::BuildVersion.semver
end
