# frozen_string_literal: true

require 'mixlib/shellout'
require 'uri'
require 'net/http'
require 'json'

# rubocop:disable Metrics/MethodLength
def capture
  telemetry_file = '/var/opt/firezone/cache/telemetry_id'
  return unless File.exist?(telemetry_file)

  telemetry_id = File.read(telemetry_file)

  return unless telemetry_id

  uri = URI('https://telemetry.firez.one/capture/')
  data = {
    api_key: 'phc_xnIRwzHSaI6c81ukilv09w2TRWUJIRo4VCxshvl7znY',
    event: 'firezone-ctl force-cert-renewal',
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

add_command_under_category 'force-cert-renewal', 'general', 'Force certificate renewal now even if it hasn\'t expired.',
                           2 do
  command = %W(
    chef-client
    -z
    -l info
    -c #{base_path}/embedded/cookbooks/solo.rb
    -o recipe[firezone::force_renewal]
  )

  capture

  result = run_command(command.join(' '))
  remove_old_node_state
  Kernel.exit 1 unless result.success?
end
