# frozen_string_literal: false

require 'json'
require 'fileutils'
require 'securerandom'

# Manages configuration
class Firezone
  # rubocop:disable Metrics/ModuleLength
  # Config module
  module Config
    class IncompleteConfig < StandardError; end
    class IncompatibleConfig < StandardError; end

    # rubocop:disable Metrics/MethodLength
    def self.load_or_create!(filename, node)
      create_directory!(filename)
      if File.exist?(filename)
        node.from_file(filename)
      else
        # Write out the new file, but with everything commented out
        File.open(filename, 'w') do |file|
          File.open(
            "#{node['firezone']['install_directory']}/embedded/cookbooks/firezone/attributes/default.rb", 'r'
          ).read.each_line do |line|
            file.write "# #{line}"
          end
        end
        Chef::Log.info("Creating configuration file #{filename}")
      end
    rescue Errno::ENOENT => e
      Chef::Log.warn "Could not create #{filename}: #{e}"
    end
    # rubocop:enable Metrics/MethodLength

    def self.load_or_create_telemetry_id(filename, node)
      create_directory!(filename)
      if File.exist?(filename)
        node.consume_attributes('firezone' => { 'telemetry_id' => File.read(filename) })
      else
        telemetry_id = SecureRandom.uuid
        File.open(filename, 'w') do |file|
          file.write telemetry_id
        end
        node.consume_attributes('firezone' => { 'telemetry_id' => telemetry_id })
      end
    end

    def self.locale_variables
      <<~LOCALE
        export LANG=en_US.UTF-8
        export LANGUAGE=en_US
        export LC_CTYPE="en_US.UTF-8"
        export LC_NUMERIC="en_US.UTF-8"
        export LC_TIME="en_US.UTF-8"
        export LC_COLLATE="en_US.UTF-8"
        export LC_MONETARY="en_US.UTF-8"
        export LC_MESSAGES="en_US.UTF-8"
        export LC_PAPER="en_US.UTF-8"
        export LC_NAME="en_US.UTF-8"
        export LC_ADDRESS="en_US.UTF-8"
        export LC_TELEPHONE="en_US.UTF-8"
        export LC_MEASUREMENT="en_US.UTF-8"
        export LC_IDENTIFICATION="en_US.UTF-8"
        export LC_ALL="en_US.UTF-8"
      LOCALE
    end

    # Read in a JSON file for attributes and consume them
    def self.load_from_json!(filename, node)
      create_directory!(filename)
      if File.exist?(filename)
        node.consume_attributes(
          'firezone' => Chef::JSONCompat.from_json(File.open(filename).read)
        )
      end
    rescue StandardError => e
      Chef::Log.warn "Could not read attributes from #{filename}: #{e}"
    end

    # Read in the filename (as JSON) and add its attributes to the node object.
    # If it doesn't exist, create it with generated secrets.
    def self.load_or_create_secrets!(filename, node)
      create_directory!(filename)
      secrets = build_secrets(node)

      # Merge in existing secrets from JSON file
      File.exist?(filename) && secrets.merge!(Chef::JSONCompat.from_json(File.read(filename)))

      # Apply to running system
      node.consume_attributes('firezone' => secrets)

      # Save them for next run
      write_secrets(filename, secrets)
    end

    def self.write_secrets(filename, secrets)
      File.open(filename, 'w') do |file|
        file.puts Chef::JSONCompat.to_json_pretty(secrets)
      end
      Chef::Log.info("Creating secrets file #{filename}")
    rescue Errno::EACCES, Errno::ENOENT => e
      Chef::Log.warn "Could not create #{filename}: #{e}"
    end

    # rubocop:disable Metrics/PerceivedComplexity
    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/AbcSize
    def self.build_secrets(node)
      {
        'guardian_secret_key' => node['firezone'] && node['firezone']['guardian_secret_key'] || SecureRandom.base64(48),
        'secret_key_base' => node['firezone'] && node['firezone']['secret_key_base'] || SecureRandom.base64(48),
        'live_view_signing_salt' => node['firezone'] && node['firezone']['live_view_signing_salt'] || \
          SecureRandom.base64(24),
        'cookie_signing_salt' => node['firezone'] && node['firezone']['cookie_signing_salt'] || SecureRandom.base64(6),
        'cookie_encryption_salt' => node['firezone'] && node['firezone']['cookie_encryption_salt'] || \
          SecureRandom.base64(6),
        'wireguard_private_key' => node['firezone'] && node['firezone']['wireguard_private_key'] || \
          `#{node['firezone']['install_directory']}/embedded/bin/wg genkey`.chomp,
        'database_encryption_key' => node['firezone'] && node['firezone']['database_encryption_key'] || \
          SecureRandom.base64(32),
        'default_admin_password' => node['firezone'] && node['firezone']['default_admin_password'] || \
          SecureRandom.base64(12)
      }
    end
    # rubocop:enable Metrics/PerceivedComplexity
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/AbcSize

    def self.audit_config(config)
      audit_fips_config(config)
    end

    def self.audit_fips_config(config)
      return if built_with_fips?(config['install_directory'])

      if fips_enabled_in_kernel?
        raise IncompatibleConfig,
              'Detected FIPS is enabled in the kernel, but FIPS is not supported by this installer.'
      end
      return unless config['fips_enabled']

      raise IncompatibleConfig,
            'You have enabled FIPS in your configuration, but FIPS is not supported by this installer.'
    end

    def self.built_with_fips?(install_directory)
      File.exist?("#{install_directory}/embedded/lib/fipscanister.o")
    end

    def self.fips_enabled_in_kernel?
      fips_path = '/proc/sys/crypto/fips_enabled'
      (File.exist?(fips_path) && File.read(fips_path).chomp != '0')
    end

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def self.maybe_turn_on_fips(node)
      # the compexity of this method is currently needed to figure out what words to display
      # to the poor human who has to deal with FIPS
      case node['firezone']['fips_enabled']
      when nil
        # the default value, set fips mode based on whether it is enabled in the kernel
        node.normal['firezone']['fips_enabled'] = Firezone::Config.fips_enabled_in_kernel?
        if node['firezone']['fips_enabled']
          Chef::Log.warn('Detected FIPS-enabled kernel; enabling FIPS 140-2 for Firezone services.')
        end
      when false
        node.normal['firezone']['fips_enabled'] = Firezone::Config.fips_enabled_in_kernel?
        if node['firezone']['fips_enabled']
          Chef::Log.warn('Detected FIPS-enabled kernel; enabling FIPS 140-2 for Firezone services.')
          Chef::Log.warn('fips_enabled was set to false; ignoring this and setting to true or else Firezone services'\
                         ' will fail with crypto errors.')
        end
      when true
        Chef::Log.warn('Overriding FIPS detection: FIPS 140-2 mode is ON.')
      else
        node.normal['firezone']['fips_enabled'] = true
        Chef::Log.warn(
          'fips_enabled is set to something other than boolean true/false; assuming FIPS mode should be enabled.'
        )
        Chef::Log.warn('Overriding FIPS detection: FIPS 140-2 mode is ON.')
      end
    end
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/AbcSize

    # Take some node attributes and return them on each line as:
    #
    # export ATTR_NAME="attr_value"
    #
    # If the value is a String or Number and the attribute name is attr_name.
    # Used to write out environment variables to a file.
    def self.environment_variables_from(attributes)
      attributes.reduce '' do |str, attr|
        str << if attr[1].is_a?(String) || attr[1].is_a?(Numeric) || attr[1] == true || attr[1] == false
                 "export #{attr[0].upcase}=\"#{attr[1]}\"\n"
               else
                 ''
               end
      end
    end

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity
    def self.app_env(node, reject = [])
      attributes = node['firezone']
      attributes = attributes.reject { |k| reject.include?(k) }

      fqdn_url = "https://#{attributes['fqdn'] || node['fqdn'] || node['hostname']}"

      # NOTE: All these variables must be Strings
      env = {
        'EGRESS_INTERFACE' => attributes['egress_interface'],
        'WG_PATH' => "#{attributes['install_directory']}/embedded/bin/wg",
        'NFT_PATH' => "#{attributes['install_directory']}/embedded/sbin/nft",
        'MIX_ENV' => 'prod',
        'DATABASE_NAME' => attributes['database']['name'],
        'DATABASE_USER' => attributes['database']['user'],
        'DATABASE_HOST' => attributes['database']['host'],
        'DATABASE_PORT' => attributes['database']['port'].to_s,
        'DATABASE_POOL' => attributes['database']['pool'].to_s,
        'DATABASE_SSL' => attributes['database']['ssl'].to_s,
        'DATABASE_SSL_OPTS' => attributes['database']['ssl_opts'].to_json,
        'DATABASE_PARAMETERS' => attributes['database']['parameters'].to_json,
        'PHOENIX_LISTEN_ADDRESS' => attributes['phoenix']['listen_address'].to_s,
        'PHOENIX_PORT' => attributes['phoenix']['port'].to_s,
        'EXTERNAL_URL' => attributes['external_url'] || fqdn_url,
        'ADMIN_EMAIL' => attributes['admin_email'],
        'WIREGUARD_INTERFACE_NAME' => attributes['wireguard']['interface_name'],
        'WIREGUARD_PORT' => attributes['wireguard']['port'].to_s,
        'WIREGUARD_MTU' => attributes['wireguard']['mtu'].to_s,
        'WIREGUARD_ENDPOINT' => attributes['wireguard']['endpoint'].to_s,
        'WIREGUARD_DNS' => attributes['wireguard']['dns'].to_s,
        'WIREGUARD_ALLOWED_IPS' => attributes['wireguard']['allowed_ips'].to_s,
        'WIREGUARD_PERSISTENT_KEEPALIVE' => attributes['wireguard']['persistent_keepalive'].to_s,
        'WIREGUARD_PUBLIC_KEY' => attributes['wireguard_public_key'],
        'WIREGUARD_PSK_DIR' => "#{attributes['var_directory']}/cache/psks",
        'WIREGUARD_IPV4_ENABLED' => attributes['wireguard']['ipv4']['enabled'].to_s,
        'WIREGUARD_IPV4_NETWORK' => attributes['wireguard']['ipv4']['network'],
        'WIREGUARD_IPV4_ADDRESS' => attributes['wireguard']['ipv4']['address'],
        'WIREGUARD_IPV6_ENABLED' => attributes['wireguard']['ipv6']['enabled'].to_s,
        'WIREGUARD_IPV6_NETWORK' => attributes['wireguard']['ipv6']['network'],
        'WIREGUARD_IPV6_ADDRESS' => attributes['wireguard']['ipv6']['address'],
        'MAX_DEVICES_PER_USER' => attributes['max_devices_per_user'].to_s,
        'ALLOW_UNPRIVILEGED_DEVICE_MANAGEMENT' => attributes['allow_unprivileged_device_management'].to_s,
        # Allow env var to override config
        'TELEMETRY_ENABLED' => ENV.fetch('TELEMETRY_ENABLED',
                                         attributes['telemetry']['enabled'] == false ? 'false' : 'true'),
        'TELEMETRY_ID' => attributes['telemetry_id'],
        'CONNECTIVITY_CHECKS_ENABLED' => attributes['connectivity_checks']['enabled'].to_s,
        'CONNECTIVITY_CHECKS_INTERVAL' => attributes['connectivity_checks']['interval'].to_s,

        # Outbound Emails
        'OUTBOUND_EMAIL_PROVIDER' => attributes['outbound_email']['provider'],
        'OUTBOUND_EMAIL_CONFIGS' => attributes['outbound_email']['configs'].to_json,
        'OUTBOUND_EMAIL_FROM' => attributes['outbound_email']['from'],

        # Auth
        'LOCAL_AUTH_ENABLED' => attributes['authentication']['local']['enabled'].to_s,
        'OKTA_AUTH_ENABLED' => attributes['authentication']['okta']['enabled'].to_s,
        'OKTA_CLIENT_ID' => attributes['authentication']['okta']['client_id'],
        'OKTA_CLIENT_SECRET' => attributes['authentication']['okta']['client_secret'],
        'OKTA_SITE' => attributes['authentication']['okta']['site'],
        'GOOGLE_AUTH_ENABLED' => attributes['authentication']['google']['enabled'].to_s,
        'GOOGLE_CLIENT_ID' => attributes['authentication']['google']['client_id'],
        'GOOGLE_CLIENT_SECRET' => attributes['authentication']['google']['client_secret'],
        'GOOGLE_REDIRECT_URI' => attributes['authentication']['google']['redirect_uri'],

        # OpenID Connect auth settings are serialized to json for consumption by fz_http
        'AUTH_OIDC' => attributes['authentication']['oidc'].to_json,

        # secrets
        'GUARDIAN_SECRET_KEY' => attributes['guardian_secret_key'],
        'SECRET_KEY_BASE' => attributes['secret_key_base'],
        'LIVE_VIEW_SIGNING_SALT' => attributes['live_view_signing_salt'],
        'COOKIE_SIGNING_SALT' => attributes['cookie_signing_salt'],
        'COOKIE_ENCRYPTION_SALT' => attributes['cookie_encryption_salt'],
        'DATABASE_ENCRYPTION_KEY' => attributes['database_encryption_key']
      }

      env.merge!('DATABASE_PASSWORD' => attributes['database']['password']) if attributes.dig('database', 'password')

      if attributes['default_admin_password']
        env.merge!('DEFAULT_ADMIN_PASSWORD' => attributes['default_admin_password'])
      end

      env
    end
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/AbcSize

    def self.create_directory!(filename)
      dir = File.dirname(filename)
      FileUtils.mkdir(dir, mode: 0o700) unless Dir.exist?(dir)
    rescue Errno::EACCES => e
      Chef::Log.warn "Could not create #{dir}: #{e}"
    end
    private_class_method :create_directory!
  end
  # rubocop:enable Metrics/ModuleLength
end
