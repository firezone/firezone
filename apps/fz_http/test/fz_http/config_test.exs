defmodule FzHttp.ConfigTest do
  use ExUnit.Case, async: true
  import FzHttp.Config

  defmodule Test do
    use FzHttp.Config.Definition
    alias FzHttp.Types

    defconfig(:required, Types.IP)

    defconfig(:optional, Types.IP, default: "0.0.0.0")

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

    defconfig(:json_array, {:array, :map})
    defconfig(:json, :map)

    defconfig(:boolean, :boolean)
  end

  describe "fetch_config/4" do
    test "returns error when required config is not set" do
      assert fetch_config(Test, :required, %{}, %{}) ==
               {:error,
                {{nil, ["is required"]}, [module: Test, key: :required, source: :not_found]}}
    end

    test "returns default value when config is not set" do
      assert fetch_config(Test, :optional, %{}, %{}) ==
               {:ok, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: nil}}

      assert fetch_config(Test, :optional_generated, %{}, %{}) ==
               {:ok, %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}}
    end

    test "returns error when resolved value is invalid" do
      assert fetch_config(Test, :invalid_with_validation, %{}, %{}) ==
               {:error,
                {{-1, ["must be greater than or equal to 0"]},
                 [
                   module: FzHttp.ConfigTest.Test,
                   key: :invalid_with_validation,
                   source: :default
                 ]}}

      assert fetch_config(Test, :required, %{required: "a.b.c.d"}, %{}) ==
               {:error,
                {{"a.b.c.d", ["is invalid IP address"]},
                 [
                   module: FzHttp.ConfigTest.Test,
                   key: :required,
                   source: {:db, :required}
                 ]}}

      assert fetch_config(Test, :one_of, %{one_of: :atom}, %{}) ==
               {:error,
                {{:atom, ["must be one of: string, integer"]},
                 [
                   module: FzHttp.ConfigTest.Test,
                   key: :one_of,
                   source: {:db, :one_of}
                 ]}}

      assert fetch_config(Test, :array, %{}, %{}) ==
               {:error,
                {[{3, ["must be less than or equal to 2"]}],
                 [module: FzHttp.ConfigTest.Test, key: :array, source: :default]}}
    end

    test "casts binary to appropriate data type" do
      assert fetch_config(Test, :array, %{}, %{"ARRAY" => "0,1,2"}) ==
               {:ok, [0, 1, 2]}

      json = Jason.encode!(%{foo: :bar})

      assert fetch_config(Test, :json, %{}, %{"JSON" => json}) ==
               {:ok, %{"foo" => "bar"}}

      json = Jason.encode!([%{foo: :bar}])

      assert fetch_config(Test, :json_array, %{}, %{"JSON_ARRAY" => json}) ==
               {:ok, [%{"foo" => "bar"}]}

      assert fetch_config(Test, :optional, %{}, %{"OPTIONAL" => "127.0.0.1"}) ==
               {:ok, %Postgrex.INET{address: {127, 0, 0, 1}, netmask: nil}}

      assert fetch_config(Test, :boolean, %{}, %{"BOOLEAN" => "true"}) ==
               {:ok, true}
    end

    test "returns error when type can not be casted" do
      assert fetch_config(Test, :integer, %{}, %{"INTEGER" => "X"}) ==
               {:error,
                {{"X", ["can not be cast to an integer"]},
                 [
                   module: FzHttp.ConfigTest.Test,
                   key: :integer,
                   source: {:env, "INTEGER"}
                 ]}}

      assert fetch_config(Test, :integer, %{}, %{"INTEGER" => "123a"}) ==
               {:error,
                {{"123a",
                  ["can not be cast to an integer, got a reminder a after an integer value 123"]},
                 [
                   module: FzHttp.ConfigTest.Test,
                   key: :integer,
                   source: {:env, "INTEGER"}
                 ]}}

      json = Jason.encode!(%{foo: :bar})

      assert fetch_config(Test, :json, %{}, %{"JSON" => json}) ==
               {:ok, %{"foo" => "bar"}}

      json = Jason.encode!([%{foo: :bar}])

      assert fetch_config(Test, :json_array, %{}, %{"JSON_ARRAY" => json}) ==
               {:ok, [%{"foo" => "bar"}]}
    end

    test "returns value for a given config using resolver precedence" do
      key = :optional_generated

      # Generated default value
      assert fetch_config(Test, key, %{}, %{}) == {:ok, %Postgrex.INET{address: {1, 1, 1, 1}}}

      # DB value overrides default
      db = %{optional_generated: "2.2.2.2"}
      assert fetch_config(Test, key, db, %{}) == {:ok, %Postgrex.INET{address: {2, 2, 2, 2}}}

      # Legacy env overrides DB
      env = %{"OGID" => "3.3.3.3"}
      assert fetch_config(Test, key, db, env) == {:ok, %Postgrex.INET{address: {3, 3, 3, 3}}}

      # Env overrides legacy env
      env = Map.merge(env, %{"OPTIONAL_GENERATED" => "4.4.4.4"})
      assert fetch_config(Test, key, db, env) == {:ok, %Postgrex.INET{address: {4, 4, 4, 4}}}
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

       - `\"a.b.c.d\"`: is invalid IP address\
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
  end

  describe "validate_runtime_config/0" do
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
        validate_runtime_config(Test, %{}, %{})
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

      assert validate_runtime_config(Test, %{}, env_config) == :ok
    end
  end
end
