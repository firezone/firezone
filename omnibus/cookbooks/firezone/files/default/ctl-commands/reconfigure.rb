require 'mixlib/shellout'

add_command_under_category 'reconfigure', 'general', 'Reconfigure the application.', 2 do
  status = run_chef("#{base_path}/embedded/cookbooks/dna.json", '--chef-license=accept')
  if status.success?
    log "#{display_name} Reconfigured!"
    exit! 0
  else
    exit! 1
  end
end
