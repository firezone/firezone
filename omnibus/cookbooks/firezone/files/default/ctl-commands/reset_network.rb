# frozen_string_literal: true

require 'mixlib/shellout'

add_command_under_category 'reset-network', 'general', 'Resets nftables, WireGuard interface, '\
  'and routing table back to Firezone defaults.', 2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::teardown],recipe[firezone::network]
  )

  result = run_command(command.join(' '))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
