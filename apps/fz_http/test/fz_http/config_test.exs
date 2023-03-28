defmodule FzHttp.ConfigTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Config

  defmodule Test do
    use FzHttp.Config.Definition
    alias FzHttp.Types

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
        |> FzHttp.Validator.validate_uri(key)
        |> FzHttp.Validator.normalize_url(key)
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

  describe "fetch_source_and_config!/1" do
    test "returns source and config value" do
      assert fetch_source_and_config!(:default_client_mtu) ==
               {{:db, :default_client_mtu}, 1280}
    end

    test "raises an error when value is missing" do
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
        fetch_source_and_config!(:external_url)
      end
    end
  end

  describe "fetch_source_and_configs!/1" do
    test "returns source and config values" do
      assert fetch_source_and_configs!([:default_client_mtu, :default_client_dns]) ==
               %{
                 default_client_dns:
                   {{:db, :default_client_dns},
                    [
                      %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil},
                      %Postgrex.INET{address: {1, 0, 0, 1}, netmask: nil}
                    ]},
                 default_client_mtu: {{:db, :default_client_mtu}, 1280}
               }
    end

    test "raises an error when value is missing" do
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
        fetch_source_and_configs!([:external_url])
      end
    end

    test "raises an error when value is invalid" do
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
        fetch_source_and_configs!([:external_url])
      end
    end
  end

  describe "fetch_config/1" do
    test "returns config value" do
      assert fetch_config(:default_client_mtu) ==
               {:ok, 1280}
    end

    test "returns error when value is missing" do
      assert fetch_config(:external_url) ==
               {:error,
                {{nil, ["is required"]},
                 [module: FzHttp.Config.Definitions, key: :external_url, source: :not_found]}}
    end
  end

  describe "fetch_config!/1" do
    test "returns config value" do
      assert fetch_config!(:default_client_mtu) ==
               1280
    end

    test "raises when value is missing" do
      assert_raise RuntimeError, fn ->
        fetch_config!(:external_url)
      end
    end
  end

  describe "fetch_configs!/1" do
    test "returns source and config values" do
      assert fetch_configs!([:default_client_mtu, :default_client_dns]) ==
               %{
                 default_client_dns: [
                   %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil},
                   %Postgrex.INET{address: {1, 0, 0, 1}, netmask: nil}
                 ],
                 default_client_mtu: 1280
               }
    end

    test "raises an error when value is missing" do
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
        fetch_configs!([:external_url])
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
      assert compile_config!(Test, :enum, %{"ENUM" => "value2"}) == FzHttp.ConfigTest.Test

      assert compile_config!(Test, :enum, %{"ENUM" => "Elixir.FzHttp.ConfigTest.Test"}) ==
               FzHttp.ConfigTest.Test
    end
  end

  describe "validate_runtime_config!/0" do
    test "raises error on invalid values" do
      message = """
      Found 9 configuration errors:


      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'url'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          URL=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'boolean'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          BOOLEAN=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'json'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          JSON=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'json_array'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          JSON_ARRAY=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Invalid configuration for 'array' retrieved from default value.

      Errors:

       - `3`: must be less than or equal to 2


      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Invalid configuration for 'invalid_with_validation' retrieved from default value.

      Errors:

       - `-1`: must be greater than or equal to 0


      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'integer'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          INTEGER=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'one_of'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          ONE_OF=YOUR_VALUE



      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

      Missing required configuration value for 'required'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration via environment variable by adding it to `.env` file:

          REQUIRED=YOUR_VALUE
      """

      assert_raise RuntimeError, message, fn ->
        validate_runtime_config!(Test, %{}, %{})
      end
    end

    test "returns :ok when config is valid" do
      env_config = %{
        "BOOLEAN" => "true",
        "ARRAY" => "1",
        "JSON" => "{\"foo\":\"bar\"}",
        "JSON_ARRAY" => "[{\"foo\":\"bar\"}]",
        "INTEGER" => "123",
        "ONE_OF" => "a",
        "REQUIRED" => "1.1.1.1",
        "INVALID_WITH_VALIDATION" => "2",
        "URL" => "http://example.com"
      }

      assert validate_runtime_config!(Test, %{}, env_config) == :ok
    end
  end

  describe "fetch_db_config!" do
    test "returns config from db table" do
      assert fetch_db_config!() == Repo.one(FzHttp.Config.Configuration)
    end
  end

  describe "change_config/2" do
    test "returns config changeset" do
      assert %Ecto.Changeset{} = change_config()
    end
  end

  describe "update_config/2" do
    test "returns error when changeset is invalid" do
      config = Repo.one(FzHttp.Config.Configuration)

      attrs = %{
        local_auth_enabled: 1,
        allow_unprivileged_device_management: 1,
        allow_unprivileged_device_configuration: 1,
        disable_vpn_on_oidc_error: 1,
        default_client_persistent_keepalive: -1,
        default_client_mtu: -1,
        default_client_endpoint: "123",
        default_client_dns: ["!!!"],
        default_client_allowed_ips: ["!"],
        vpn_session_duration: -1
      }

      assert {:error, changeset} = update_config(config, attrs)

      assert errors_on(changeset) == %{
               default_client_mtu: ["must be greater than or equal to 576"],
               allow_unprivileged_device_configuration: ["is invalid"],
               allow_unprivileged_device_management: ["is invalid"],
               default_client_allowed_ips: ["is invalid"],
               default_client_dns: [
                 "!!! is not a valid FQDN",
                 "must be one of: Elixir.FzHttp.Types.IP, string"
               ],
               default_client_persistent_keepalive: ["must be greater than or equal to 0"],
               disable_vpn_on_oidc_error: ["is invalid"],
               local_auth_enabled: ["is invalid"],
               vpn_session_duration: ["must be greater than or equal to 0"]
             }
    end

    test "returns error when trying to change overridden value" do
      put_system_env_override(:local_auth_enabled, false)

      config = Repo.one(FzHttp.Config.Configuration)

      attrs = %{
        local_auth_enabled: false
      }

      assert {:error, changeset} = update_config(config, attrs)

      assert errors_on(changeset) ==
               %{
                 local_auth_enabled: [
                   "cannot be changed; it is overridden by LOCAL_AUTH_ENABLED environment variable"
                 ]
               }
    end

    test "trims binary fields" do
      config = Repo.one(FzHttp.Config.Configuration)

      attrs = %{
        default_client_dns: ["   foobar.com", "google.com   "],
        default_client_endpoint: "   127.0.0.1    "
      }

      assert {:ok, config} = update_config(config, attrs)
      assert config.default_client_dns == ["foobar.com", "google.com"]
      assert config.default_client_endpoint == "127.0.0.1"
    end

    test "changes database config value" do
      config = Repo.one(FzHttp.Config.Configuration)
      attrs = %{default_client_dns: ["foobar.com", "google.com"]}
      assert {:ok, config} = update_config(config, attrs)
      assert config.default_client_dns == attrs.default_client_dns
    end
  end

  describe "put_config!/2" do
    test "updates config field in a database" do
      assert config = put_config!(:default_client_endpoint, " 127.0.0.1")
      assert config.default_client_endpoint == "127.0.0.1"
      assert Repo.one(FzHttp.Config.Configuration).default_client_endpoint == "127.0.0.1"
    end

    test "raises when config field is not valid" do
      assert_raise RuntimeError, fn ->
        put_config!(:default_client_endpoint, "!!!")
      end
    end
  end
end
