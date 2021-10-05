# frozen_string_literal: true

require 'mixlib/shellout'

add_command_under_category 'create-admin', 'general', 'Create an Admin user', 2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::create_admin]
  )

  result = run_command(command.join(" "))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
