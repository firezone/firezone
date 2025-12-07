defmodule Domain.ConfigTest do
  use Domain.DataCase, async: true
  import Domain.Config

  defmodule Test do
    use Domain.Config.Definition
    alias Domain.Types

    defconfig(:required, Types.IP)

    defconfig(:optional_generated, Types.IP, default: fn -> "1.1.1.1" end)

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
        |> Domain.Changeset.validate_uri(key)
        |> Domain.Changeset.normalize_url(key)
      end
    )

    defconfig(
      :enum,
      Ecto.ParameterizedType.init(Ecto.Enum, values: [:value1, :value2, __MODULE__]),
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

      %{account: account}
    end

    test "returns source and config values", %{account: account} do
      assert fetch_resolved_configs!(account.id, [:outbound_email_adapter, :docker_registry]) ==
               %{
                 outbound_email_adapter: nil,
                 docker_registry: "ghcr.io/firezone"
               }
    end

    test "raises an error when value is missing", %{account: account} do
      message = """
      Missing required configuration value for 'secret_key_base'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration with an environment variable:

          SECRET_KEY_BASE=YOUR_VALUE


      ## Documentation

      Primary secret key base for the Phoenix application.

      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs!(account.id, [:secret_key_base])
      end
    end
  end

  describe "fetch_resolved_configs_with_sources!/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      %{account: account}
    end

    test "returns source and config values", %{account: account} do
      %{
        docker_registry: "ghcr.io/firezone"
      }

      assert fetch_resolved_configs_with_sources!(account.id, [
               :outbound_email_adapter,
               :docker_registry
             ]) ==
               %{
                 outbound_email_adapter: {:default, nil},
                 docker_registry: {:default, "ghcr.io/firezone"}
               }
    end

    test "raises an error when value is missing", %{account: account} do
      message = """
      Missing required configuration value for 'secret_key_base'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration with an environment variable:

          SECRET_KEY_BASE=YOUR_VALUE


      ## Documentation

      Primary secret key base for the Phoenix application.

      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs_with_sources!(account.id, [:secret_key_base])
      end
    end

    test "raises an error when value is invalid", %{account: account} do
      put_system_env_override(:web_external_url, "https://example.com/vpn")

      message = """
      Invalid configuration for 'web_external_url' retrieved from environment variable WEB_EXTERNAL_URL.

      Errors:

       - `"https://example.com/vpn"`: does not end with a trailing slash

      ## Documentation

      The external URL the UI will be accessible at.

      If this field is not set or set to `nil`, the server for `api` and `web` apps will not start.

      """

      assert_raise RuntimeError, message, fn ->
        fetch_resolved_configs_with_sources!(account.id, [:web_external_url])
      end
    end
  end

  describe "env_var_to_config!/1" do
    test "returns config value" do
      assert env_var_to_config!(Test, :optional_generated) ==
               %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}
    end

    test "raises an error when value is missing" do
      message = """
      Missing required configuration value for 'required'.

      ## How to fix?

      ### Using environment variables

      You can set this configuration with an environment variable:

          REQUIRED=YOUR_VALUE
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :required)
      end
    end

    test "raises an error when value cannot be casted" do
      message = """
      Invalid configuration for 'integer' retrieved from environment variable INTEGER.

      Errors:

       - `"123a"`: cannot be cast to an integer, got a reminder a after an integer value 123\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :integer, %{"INTEGER" => "123a"})
      end
    end

    test "raises an error when value is invalid" do
      message = """
      Invalid configuration for 'required' retrieved from environment variable REQUIRED.

      Errors:

       - `\"a.b.c.d\"`: is invalid\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :required, %{"REQUIRED" => "a.b.c.d"})
      end

      message = """
      Invalid configuration for 'one_of' retrieved from environment variable ONE_OF.

      Errors:

       - `"X"`: must be one of: string, integer\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :one_of, %{"ONE_OF" => "X"})
      end

      message = """
      Invalid configuration for 'array' retrieved from environment variable ARRAY.

      Errors:

       - `-2`: must be greater than or equal to 0
       - `-100`: must be greater than or equal to 0
       - `-1`: must be greater than or equal to 0\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :array, %{"ARRAY" => "1,-1,0,2,-100,-2"})
      end

      message = """
      Invalid configuration for 'url' retrieved from environment variable URL.

      Errors:

       - `"foo.bar/baz"`: does not contain a scheme or a host\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :url, %{"URL" => "foo.bar/baz"})
      end
    end

    test "does not print sensitive values" do
      message = """
      Invalid configuration for 'sensitive' retrieved from environment variable SENSITIVE.

      Errors:

       - `**SENSITIVE-VALUE-REDACTED**`: {:unexpected_end, 3}\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :sensitive, %{"SENSITIVE" => "foo"})
      end
    end

    test "returns error on invalid enum values" do
      message = """
      Invalid configuration for 'enum' retrieved from environment variable ENUM.

      Errors:

       - `"foo"`: is invalid\
      """

      assert_raise RuntimeError, message, fn ->
        env_var_to_config!(Test, :enum, %{"ENUM" => "foo"})
      end
    end

    test "casts module name enums" do
      assert env_var_to_config!(Test, :enum, %{"ENUM" => "value1"}) == :foo
      assert env_var_to_config!(Test, :enum, %{"ENUM" => "value2"}) == Domain.ConfigTest.Test

      assert env_var_to_config!(Test, :enum, %{"ENUM" => "Elixir.Domain.ConfigTest.Test"}) ==
               Domain.ConfigTest.Test
    end
  end
end
