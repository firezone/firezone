# frozen_string_literal: true

require 'mixlib/shellout'
require 'uri'
require 'net/http'
require 'json'

desc = <<~DESC
Resets the password for admin with email specified by default['firezone']['admin_email'] or creates a new admin if that email doesn't exist.
DESC

def capture
  fqdn = Mixlib::ShellOut.new("hostname -f").run_command.stdout
  uri = URI("https://telemetry.firez.one/capture/")
  data = {
    api_key: "phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK",
    event: "firezone-ctl create-or-reset-admin",
    properties: {
      distinct_id: fqdn
    }
  }
  unless File.exist?("#{base_path}/.telemetry-disable")
    Net::HTTP.post(uri, data.to_json, "Content-Type" => "application/json")
  end
end

add_command_under_category 'create-or-reset-admin', 'general', desc, 2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::create_admin]
  )

  capture

  result = run_command(command.join(" "))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
