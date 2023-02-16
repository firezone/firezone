defmodule FzHttp.ConfigTest do
  use ExUnit.Case, async: true
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

    test "raises an error when value can not be casted" do
      message = """
      Invalid configuration for 'integer' retrieved from environment variable INTEGER.

      Errors:

       - `"123a"`: can not be cast to an integer, got a reminder a after an integer value 123\
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
  end

  describe "validate_runtime_config!/0" do
    test "raises error on invalid values" do
      message = """
      Found 8 configuration errors:


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
        "INVALID_WITH_VALIDATION" => "2"
      }

      assert validate_runtime_config!(Test, %{}, env_config) == :ok
    end
  end

  # describe "update_configuration/2 with name-based default_client_dns" do
  #   test "update_configuration/2 allows hosts for DNS" do
  #     configuration = configuration(%{})
  #     attrs = %{default_client_dns: ["foobar.com"]}
  #     assert {:ok, _configuration} = update_configuration(configuration, attrs)
  #   end

  #   test "update_configuration/2 allows list hosts for DNS" do
  #     configuration = configuration(%{})
  #     attrs = %{default_client_dns: ["foobar.com", "google.com"]}
  #     assert {:ok, _configuration} = update_configuration(configuration, attrs)
  #   end
  # end

  # describe "configurations" do
  #   @valid_configurations [
  #     %{
  #       "default_client_dns" => ["8.8.8.8"],
  #       "default_client_allowed_ips" => ["::/0"],
  #       "default_client_endpoint" => "172.10.10.10",
  #       "default_client_persistent_keepalive" => "20",
  #       "default_client_mtu" => "1280"
  #     },
  #     %{
  #       "default_client_dns" => ["8.8.8.8"],
  #       "default_client_allowed_ips" => ["::/0"],
  #       "default_client_endpoint" => "foobar.example.com",
  #       "default_client_persistent_keepalive" => "15",
  #       "default_client_mtu" => "1280"
  #     }
  #   ]
  #   @invalid_configuration %{
  #     "default_client_dns" => "foobar",
  #     "default_client_allowed_ips" => "foobar",
  #     "default_client_endpoint" => "foobar",
  #     "default_client_persistent_keepalive" => "-120",
  #     "default_client_mtu" => "1501"
  #   }

  #   test "get_configuration/1 returns the configuration" do
  #     configuration = configuration(%{})
  #     assert get_configuration!() == configuration
  #   end

  #   test "update_configuration/2 with valid data updates the configuration via provided configuration" do
  #     configuration = get_configuration!()

  #     for attrs <- @valid_configurations do
  #       assert {:ok, %Configuration{}} = update_configuration(configuration, attrs)
  #     end
  #   end

  #   test "update_configuration/2 with invalid data returns error changeset" do
  #     configuration = get_configuration!()

  #     assert {:error, %Ecto.Changeset{}} =
  #              update_configuration(configuration, @invalid_configuration)

  #     configuration = get_configuration!()

  #     refute configuration.default_client_dns == "foobar"
  #     refute configuration.default_client_allowed_ips == "foobar"
  #     refute configuration.default_client_endpoint == "foobar"
  #     refute configuration.default_client_persistent_keepalive == -120
  #     refute configuration.default_client_mtu == 1501
  #   end

  #   test "change_configuration/1 returns a configuration changeset" do
  #     configuration = configuration(%{})
  #     assert %Ecto.Changeset{} = change_configuration(configuration)
  #   end
  # end

  # describe "trimmed fields" do
  #   test "trims expected fields" do
  #     changeset =
  #       change_configuration(%Configuration{}, %{
  #         "default_client_dns" => [" foo "],
  #         "default_client_endpoint" => " foo "
  #       })

  #     assert %Ecto.Changeset{
  #              changes: %{
  #                default_client_dns: ["foo"],
  #                default_client_endpoint: "foo"
  #              }
  #            } = changeset
  #   end
  # end
end
