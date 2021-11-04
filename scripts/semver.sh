#!/usr/bin/env ruby

require 'omnibus'
Omnibus::Config.append_timestamp false
print Omnibus::BuildVersion.semver
