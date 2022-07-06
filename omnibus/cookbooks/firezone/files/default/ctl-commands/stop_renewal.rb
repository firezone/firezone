# frozen_string_literal: true

require 'mixlib/shellout'

add_command_under_category 'stop-cert-renewal', 'general', 'Removes cronjob that renews certificates',
                           2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::stop_renewal]
  )

  result = run_command(command.join(' '))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
