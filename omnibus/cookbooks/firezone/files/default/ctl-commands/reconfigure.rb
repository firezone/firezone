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
    api_key: 'phc_ubuPhiqqjMdedpmbWpG2Ak3axqv5eMVhFDNBaXl9UZK',
    event: 'firezone-ctl reconfigure',
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

add_command_under_category 'reconfigure', 'general', 'Reconfigure the application.', 2 do
  status = run_chef("#{base_path}/embedded/cookbooks/dna.json", '--chef-license=accept')

  msg = <<~MSG
    =================================================================================

    Heads up! We've announced a new public beta program. Sign up to receive a free
    license key good for up to one year of Firezone Team or Business. Read more about
    the announcement here:

    https://www.firezone.dev/blog/release-0-5-0

    =================================================================================
  MSG

  Chef::Log.info(msg)

  capture

  if status.success?
    log "#{display_name} Reconfigured!"
    exit! 0
  else
    exit! 1
  end
end
