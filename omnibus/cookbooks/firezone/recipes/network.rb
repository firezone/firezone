# frozen_string_literal: true

# Cookbook:: firezone
# Recipe:: network
#
# Copyright:: 2021, Firezone, All Rights Reserved.

# Set up wireguard interface, default routes, and firewall
# rules so that Firezone can run without a hitch.
#
# This recipe basically performs the work of wg-quick without having to
# have a configuration file.

include_recipe 'firezone::config'
include_recipe 'line::default'

require 'mixlib/shellout'

# Use ip route for finding default egress interface
awk_path = "#{node['firezone']['install_directory']}/embedded/bin/awk"
egress_int_cmd = Mixlib::ShellOut.new("ip route show default 0.0.0.0/0 | grep -oP '(?<=dev ).*' | cut -f1 -d' '")
egress_interface = egress_int_cmd.run_command.stdout.chomp
# Set default endpoint ip to default egress ip
egress_addr_cmd = "ip address show dev #{egress_interface} | grep 'inet ' | #{awk_path} '{print $2}'"
egress_ip = Mixlib::ShellOut.new(egress_addr_cmd)
egress_ip.run_command

node.default['firezone']['wireguard']['endpoint'] ||= egress_ip.stdout.chomp.gsub(%r{/.*}, '')
node.default['firezone']['egress_interface'] = egress_interface

replace_or_add 'IPv4 packet forwarding' do
  path '/etc/sysctl.conf'
  pattern(/^\s+#\s+net.ipv4.ip_forward\s+=\s+1/)
  line 'net.ipv4.ip_forward=1'
end

replace_or_add 'IPv6 packet forwarding' do
  path '/etc/sysctl.conf'
  pattern(/^\s+#\s+net.ipv6.conf.all.forwarding\s+=\s+1/)
  line 'net.ipv6.conf.all.forwarding=1'
end

execute 'sysctl -p /etc/sysctl.conf'
