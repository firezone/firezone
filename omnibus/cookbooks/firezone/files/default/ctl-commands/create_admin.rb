# frozen_string_literal: true

require 'mixlib/shellout'

desc = <<~DESC
Resets the password for admin with email specified by default['firezone']['admin_email'] or creates a new admin if that email doesn't exist.
DESC

add_command_under_category 'create-or-reset-admin', 'general', desc, 2 do
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
