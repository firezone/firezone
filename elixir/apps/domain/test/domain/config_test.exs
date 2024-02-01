defmodule Domain.ConfigTest do
  use Domain.DataCase, async: true
  import Domain.Config
  alias Domain.Config

  defmodule Test do
    use Domain.Config.Definition
    alias Domain.Types

    defconfig(:required, Types.IP)

    defconfig(:optional_generated, Types.IP,
      legacy_keys: [{:env, "OGID", "1.0"}],
      default: fn -> "1.1.1.1" end
    )

    defconfig(:one_of, {:one_of, [:string, :integer]},
      changeset: fn
        :integer, changeset, key ->
          Ecto.Changeset.validate_number(changeset, key,
            greater_than_or_equal_to: 0,
            less_than_or_equal_to: 2
          )

        :string, changeset, key ->
          Ecto.Changeset.validate_inclusion(changeset, key, ~w[a b])
      end
    )

    defconfig(:integer, :integer)

    defconfig(:invalid_with_validation, :integer,
      default: -1,
      changeset: fn changeset, key ->
        Ecto.Changeset.validate_number(changeset, key,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 2
        )
      end
    )

    defconfig(:array, {:array, ",", :integer},
      default: [1, 2, 3],
      changeset: fn changeset, key ->
        Ecto.Changeset.validate_number(changeset, key,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 2
        )
      end
    )

    defconfig(:json_array, {:json_array, :map})

    defconfig(:json, :map,
      dump: fn value ->
        for {k, v} <- value, do: {String.to_atom(k), v}
      end
    )

    defconfig(:boolean, :boolean)

    defconfig(:sensitive, :map, default: %{}, sensitive: true)

    defconfig(:url, :string,
      changeset: fn changeset, key ->
        changeset
        |> Domain.Validator.validate_uri(key)
        |> Domain.Validator.normalize_url(key)
      end
    )

    defconfig(
      :enum,
      {:parameterized, Ecto.Enum, Ecto.Enum.init(values: [:value1, :value2, __MODULE__])},
      default: :value1,
      dump: fn
        :value1 -> :foo
        :value2 -> __MODULE__
        other -> other
      end
    )
  end

  describe "fetch_resolved_configs!/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      Fixtures.Config.upsert_configuration(account: account)

      %{account: account}
    end

    test "returns source and config values", %{account: account} do
      assert fetch_resolved_configs!(account.id, [:clients_upstream_dns, :clients_upstream_dns]) ==
               %{
                 clients_upstream_dns: [
                   %Domain.Config.Configuration.ClientsUpstreamDNS{
                     protocol: :ip_port,
                     address: "1.1.1.1"
                   },
                   %Domain.Config.Configuration.ClientsUpstreamDNS{
                     protocol: :ip_port,
                     address: "2606:4700:4700::1111"
                   },
                   %Domain.Config.Configuration.ClientsUpstreamDNS{
                     protocol: :ip_port,
                     address: "8.8.8.8:853"
                   }
                 ]
               }
    end

    test "raises an error when value is missing", %{account: account} do
      message = """
      Missing required configuration value for 'external_url'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          EXTERNAL_URL=YOUR_VALUE


      ## Documentation

      The external URL the web UI will be accessible at.

      Must be a valid and public FQDN for ACME SSL issuance to function.

      You can add a path suffix if you want to serve firezone from a non-root path,
      eg: `https://firezone.mycorp.com/vpn/`.


      You can find more information on configuration here: https://www.firezone.dev/docs/reference/env-vars/#environment-variable-listing
      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs!(account.id, [:external_url])
      end
    end
  end

  describe "fetch_resolved_configs_with_sources!/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      Fixtures.Config.upsert_configuration(account: account)

      %{account: account}
    end

    test "returns source and config values", %{account: account} do
      assert fetch_resolved_configs_with_sources!(account.id, [:clients_upstream_dns]) ==
               %{
                 clients_upstream_dns:
                   {{:db, :clients_upstream_dns},
                    [
                      %Domain.Config.Configuration.ClientsUpstreamDNS{
                        protocol: :ip_port,
                        address: "1.1.1.1"
                      },
                      %Domain.Config.Configuration.ClientsUpstreamDNS{
                        protocol: :ip_port,
                        address: "2606:4700:4700::1111"
                      },
                      %Domain.Config.Configuration.ClientsUpstreamDNS{
                        protocol: :ip_port,
                        address: "8.8.8.8:853"
                      }
                    ]}
               }
    end

    test "raises an error when value is missing", %{account: account} do
      message = """
      Missing required configuration value for 'external_url'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          EXTERNAL_URL=YOUR_VALUE


      ## Documentation

      The external URL the web UI will be accessible at.

      Must be a valid and public FQDN for ACME SSL issuance to function.

      You can add a path suffix if you want to serve firezone from a non-root path,
      eg: `https://firezone.mycorp.com/vpn/`.


      You can find more information on configuration here: https://www.firezone.dev/docs/reference/env-vars/#environment-variable-listing
      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs_with_sources!(account.id, [:external_url])
      end
    end

    test "raises an error when value is invalid", %{account: account} do
      put_system_env_override(:external_url, "https://example.com/vpn")

      message = """
      Invalid configuration for 'external_url' retrieved from environment variable EXTERNAL_URL.

      Errors:

       - `"https://example.com/vpn"`: does not end with a trailing slash

      ## Documentation

      The external URL the web UI will be accessible at.

      Must be a valid and public FQDN for ACME SSL issuance to function.

      You can add a path suffix if you want to serve firezone from a non-root path,
      eg: `https://firezone.mycorp.com/vpn/`.


      You can find more information on configuration here: https://www.firezone.dev/docs/reference/env-vars/#environment-variable-listing
      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs_with_sources!(account.id, [:external_url])
      end
    end
  end

  describe "compile_config!/1" do
    test "returns config value" do
      assert compile_config!(Test, :optional_generated) ==
               %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}
    end

    test "raises an error when value is missing" do
      message = """
      Missing required configuration value for 'required'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          REQUIRED=YOUR_VALUE
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :required)
      end
    end

    test "raises an error when value cannot be casted" do
      message = """
      Invalid configuration for 'integer' retrieved from environment variable INTEGER.

      Errors:

       - `"123a"`: cannot be cast to an integer, got a reminder a after an integer value 123\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :integer, %{"INTEGER" => "123a"})
      end
    end

    test "raises an error when value is invalid" do
      message = """
      Invalid configuration for 'required' retrieved from environment variable REQUIRED.

      Errors:

       - `\"a.b.c.d\"`: is invalid\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :required, %{"REQUIRED" => "a.b.c.d"})
      end

      message = """
      Invalid configuration for 'one_of' retrieved from environment variable ONE_OF.

      Errors:

       - `"X"`: must be one of: string, integer\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :one_of, %{"ONE_OF" => "X"})
      end

      message = """
      Invalid configuration for 'array' retrieved from environment variable ARRAY.

      Errors:

       - `-2`: must be greater than or equal to 0
       - `-100`: must be greater than or equal to 0
       - `-1`: must be greater than or equal to 0\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :array, %{"ARRAY" => "1,-1,0,2,-100,-2"})
      end

      message = """
      Invalid configuration for 'url' retrieved from environment variable URL.

      Errors:

       - `"foo.bar/baz"`: does not contain a scheme or a host\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :url, %{"URL" => "foo.bar/baz"})
      end
    end

    test "does not print sensitive values" do
      message = """
      Invalid configuration for 'sensitive' retrieved from environment variable SENSITIVE.

      Errors:

       - `**SENSITIVE-VALUE-REDACTED**`: unexpected byte at position 0: 0x66 ("f")\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :sensitive, %{"SENSITIVE" => "foo"})
      end
    end

    test "returns error on invalid enum values" do
      message = """
      Invalid configuration for 'enum' retrieved from environment variable ENUM.

      Errors:

       - `"foo"`: is invalid\
      """

      assert_raise RuntimeError, message, fn ->
        compile_config!(Test, :enum, %{"ENUM" => "foo"})
      end
    end

    test "casts module name enums" do
      assert compile_config!(Test, :enum, %{"ENUM" => "value1"}) == :foo
      assert compile_config!(Test, :enum, %{"ENUM" => "value2"}) == Domain.ConfigTest.Test

      assert compile_config!(Test, :enum, %{"ENUM" => "Elixir.Domain.ConfigTest.Test"}) ==
               Domain.ConfigTest.Test
    end
  end

  describe "get_account_config_by_account_id/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "returns configuration for an account if it exists", %{
      account: account
    } do
      configuration = Fixtures.Config.upsert_configuration(account: account)
      assert get_account_config_by_account_id(account.id) == configuration
    end

    test "returns default configuration for an account if it does not exist", %{
      account: account
    } do
      assert get_account_config_by_account_id(account.id) == %Domain.Config.Configuration{
               account_id: account.id,
               clients_upstream_dns: []
             }
    end
  end

  describe "fetch_account_config/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)

      %{
        account: account,
        actor: actor,
        identity: identity,
        subject: subject
      }
    end

    test "returns configuration for an account if it exists", %{
      account: account,
      subject: subject
    } do
      configuration = Fixtures.Config.upsert_configuration(account: account)
      assert fetch_account_config(subject) == {:ok, configuration}
    end

    test "returns default configuration for an account if it does not exist", %{
      account: account,
      subject: subject
    } do
      assert {:ok, config} = fetch_account_config(subject)

      assert config == %Domain.Config.Configuration{
               account_id: account.id,
               clients_upstream_dns: []
             }
    end

    test "returns error when subject does not have permission to read configuration", %{
      subject: subject
    } do
      subject = Fixtures.Auth.remove_permissions(subject)

      assert fetch_account_config(subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Config.Authorizer.manage_permission()]}}
    end
  end

  describe "change_account_config/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      configuration = Fixtures.Config.upsert_configuration(account: account)

      %{account: account, configuration: configuration}
    end

    test "returns config changeset", %{configuration: configuration} do
      assert %Ecto.Changeset{} = change_account_config(configuration)
    end
  end

  describe "update_config/3" do
    test "returns error when subject can not manage account configuration" do
      account = Fixtures.Accounts.create_account()
      config = get_account_config_by_account_id(account.id)
      actor = Fixtures.Actors.create_actor(type: :account_admin_user, account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      subject =
        Fixtures.Auth.create_subject(identity: identity)
        |> Fixtures.Auth.remove_permissions()

      assert update_config(config, %{}, subject) ==
               {:error,
                {:unauthorized,
                 reason: :missing_permissions,
                 missing_permissions: [Config.Authorizer.manage_permission()]}}
    end
  end

  describe "update_config/2" do
    setup do
      account = Fixtures.Accounts.create_account()
      %{account: account}
    end

    test "returns error when changeset is invalid", %{account: account} do
      config = get_account_config_by_account_id(account.id)

      attrs = %{
        clients_upstream_dns: [%{protocol: "ip_port", address: "!!!"}]
      }

      assert {:error, changeset} = update_config(config, attrs)

      assert errors_on(changeset) == %{
               clients_upstream_dns: [
                 %{address: ["must be a valid IP address"]}
               ]
             }
    end

    test "returns error when trying to change overridden value", %{account: account} do
      put_system_env_override(:clients_upstream_dns, [%{protocol: "ip_port", address: "1.2.3.4"}])

      config = get_account_config_by_account_id(account.id)

      attrs = %{
        clients_upstream_dns: [%{protocol: "ip_port", address: "4.1.2.3"}]
      }

      assert {:error, changeset} = update_config(config, attrs)

      assert errors_on(changeset) ==
               %{
                 clients_upstream_dns: [
                   "cannot be changed; it is overridden by CLIENTS_UPSTREAM_DNS environment variable"
                 ]
               }
    end

    test "trims binary fields", %{account: account} do
      config = get_account_config_by_account_id(account.id)

      attrs = %{
        clients_upstream_dns: [
          %{protocol: "ip_port", address: "   1.1.1.1"},
          %{protocol: "ip_port", address: "8.8.8.8   "}
        ]
      }

      assert {:ok, config} = update_config(config, attrs)

      assert config.clients_upstream_dns == [
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "1.1.1.1"
               },
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               }
             ]
    end

    test "changes database config value when it did not exist", %{account: account} do
      config = get_account_config_by_account_id(account.id)

      attrs = %{
        clients_upstream_dns: [
          %{protocol: "ip_port", address: "1.1.1.1"},
          %{protocol: "ip_port", address: "8.8.8.8"}
        ]
      }

      :ok = subscribe_to_events_in_account(account)

      assert {:ok, config} = update_config(config, attrs)

      assert config.clients_upstream_dns == [
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "1.1.1.1"
               },
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               }
             ]

      assert_receive :config_changed
    end

    test "changes database config value when it existed", %{account: account} do
      Fixtures.Config.upsert_configuration(account: account)

      config = get_account_config_by_account_id(account.id)

      attrs = %{
        clients_upstream_dns: [
          %{protocol: "ip_port", address: "8.8.8.8"},
          %{protocol: "ip_port", address: "8.8.4.4"}
        ]
      }

      assert {:ok, config} = update_config(config, attrs)

      assert config.clients_upstream_dns == [
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.8.8"
               },
               %Domain.Config.Configuration.ClientsUpstreamDNS{
                 protocol: :ip_port,
                 address: "8.8.4.4"
               }
             ]
    end
  end
end
