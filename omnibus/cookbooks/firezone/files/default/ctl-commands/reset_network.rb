# frozen_string_literal: true

require "mixlib/shellout"

add_command "reset_network", "Resets nftables, WireGuard interface, "\
  "and routing table back to FireZone defaults", 1 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::network]
  )

  result = run_command(command.join(" "))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
