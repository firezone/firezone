require 'mixlib/shellout'

add_command 'create_admin', 'Create an Admin user', 1 do
  command = %W(
  chef-client
  -z
  -c #{base_path}/embedded/cookbooks/solo.rb
  -o recipe[firezone::create_admin])

  status = run_command(command.join(" "))
  remove_old_node_state
  Kernel.exit 1 unless status.success?
end
