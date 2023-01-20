# frozen_string_literal: true

require 'mixlib/shellout'
require 'uri'
require 'net/http'
require 'json'

desc = <<~DESC
  Resets the password for admin with email specified by default['firezone']['admin_email'] or creates a new admin if that email doesn't exist.
DESC

# rubocop:disable Metrics/MethodLength
def capture
  telemetry_file = '/var/opt/firezone/cache/telemetry_id'
  return unless File.exist?(telemetry_file)

  telemetry_id = File.read(telemetry_file)

  return unless telemetry_id

  uri = URI('https://t.firez.one/capture/')
  data = {
    api_key: 'phc_xnIRwzHSaI6c81ukilv09w2TRWUJIRo4VCxshvl7znY',
    event: 'firezone-ctl create-or-reset-admin',
    properties: {
      distinct_id: telemetry_id
    }
  }
  return if File.exist?('/var/opt/firezone/.disable_telemetry') || ENV['TELEMETRY_ENABLED'] == 'false'

  Net::HTTP.post(uri, data.to_json, 'Content-Type' => 'application/json')
rescue StandardError => e
  e
end
# rubocop:enable Metrics/MethodLength

add_command_under_category 'create-or-reset-admin', 'general', desc, 2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::create_admin]
  )

  capture

  result = run_command(command.join(' '))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
