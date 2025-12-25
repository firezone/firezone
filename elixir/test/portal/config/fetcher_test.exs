defmodule Portal.Config.FetcherTest do
  use ExUnit.Case, async: true
  import Portal.Config.Fetcher

  defmodule Test do
    use Portal.Config.Definition
    alias Portal.Types

    defconfig(:required, Types.IP)

    defconfig(:optional, Types.IP, default: "0.0.0.0")

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
  end

  describe "fetch_source_and_config/4" do
    test "returns error when required config is not set" do
      assert fetch_source_and_config(Test, :required, %{}) ==
               {:error,
                {{nil, ["is required"]}, [module: Test, key: :required, source: :not_found]}}
    end

    test "does not allow to explicitly set required config to nil" do
      assert fetch_source_and_config(Test, :required, %{}) ==
               {:error,
                {{nil, ["is required"]}, [module: Test, key: :required, source: :not_found]}}

      assert fetch_source_and_config(Test, :required, %{"REQUIRED" => nil}) ==
               {:error,
                {{nil, ["is required"]}, [module: Test, key: :required, source: :not_found]}}
    end

    test "returns default value when config is not set" do
      assert fetch_source_and_config(Test, :optional, %{}) ==
               {:ok, :default, %Postgrex.INET{address: {0, 0, 0, 0}, netmask: nil}}

      assert fetch_source_and_config(Test, :optional_generated, %{}) ==
               {:ok, :default, %Postgrex.INET{address: {1, 1, 1, 1}, netmask: nil}}
    end

    test "returns error when resolved value is invalid" do
      assert fetch_source_and_config(Test, :invalid_with_validation, %{}) ==
               {:error,
                {{-1, ["must be greater than or equal to 0"]},
                 [
                   module: __MODULE__.Test,
                   key: :invalid_with_validation,
                   source: :default
                 ]}}

      assert fetch_source_and_config(Test, :array, %{}) ==
               {:error,
                {[{3, ["must be less than or equal to 2"]}],
                 [module: __MODULE__.Test, key: :array, source: :default]}}
    end

    test "casts binary to appropriate data type" do
      assert fetch_source_and_config(Test, :array, %{"ARRAY" => "0,1,2"}) ==
               {:ok, {:env, "ARRAY"}, [0, 1, 2]}

      json = JSON.encode!(%{foo: :bar})

      assert fetch_source_and_config(Test, :json, %{"JSON" => json}) ==
               {:ok, {:env, "JSON"}, foo: "bar"}

      json = JSON.encode!([%{foo: :bar}])

      assert fetch_source_and_config(Test, :json_array, %{"JSON_ARRAY" => json}) ==
               {:ok, {:env, "JSON_ARRAY"}, [%{"foo" => "bar"}]}

      assert fetch_source_and_config(Test, :optional, %{"OPTIONAL" => "127.0.0.1"}) ==
               {:ok, {:env, "OPTIONAL"}, %Postgrex.INET{address: {127, 0, 0, 1}, netmask: nil}}

      assert fetch_source_and_config(Test, :boolean, %{"BOOLEAN" => "true"}) ==
               {:ok, {:env, "BOOLEAN"}, true}
    end

    test "applies dump function" do
      json = JSON.encode!(%{foo: :bar})

      assert fetch_source_and_config(Test, :json, %{"JSON" => json}) ==
               {:ok, {:env, "JSON"}, foo: "bar"}
    end

    test "does not apply dump function on invalid values" do
      assert {:error, {{"foo", [unexpected_end: 3]}, _meta}} =
               fetch_source_and_config(Test, :json, %{"JSON" => "foo"})
    end

    test "returns error when type can't be casted" do
      assert fetch_source_and_config(Test, :integer, %{"INTEGER" => "X"}) ==
               {:error,
                {{"X", ["cannot be cast to an integer"]},
                 [
                   module: __MODULE__.Test,
                   key: :integer,
                   source: {:env, "INTEGER"}
                 ]}}

      assert fetch_source_and_config(Test, :integer, %{"INTEGER" => "123a"}) ==
               {:error,
                {{"123a",
                  ["cannot be cast to an integer, got a reminder a after an integer value 123"]},
                 [
                   module: __MODULE__.Test,
                   key: :integer,
                   source: {:env, "INTEGER"}
                 ]}}

      json = JSON.encode!(%{foo: :bar})

      assert fetch_source_and_config(Test, :json, %{"JSON" => json}) ==
               {:ok, {:env, "JSON"}, foo: "bar"}

      json = JSON.encode!([%{foo: :bar}])

      assert fetch_source_and_config(Test, :json_array, %{"JSON_ARRAY" => json}) ==
               {:ok, {:env, "JSON_ARRAY"}, [%{"foo" => "bar"}]}
    end

    test "returns value for a given config using resolver precedence" do
      key = :optional_generated

      # Generated default value
      assert fetch_source_and_config(Test, key, %{}) ==
               {:ok, :default, %Postgrex.INET{address: {1, 1, 1, 1}}}

      # env overrides default
      env = %{"OPTIONAL_GENERATED" => "3.3.3.3"}

      assert fetch_source_and_config(Test, key, env) ==
               {:ok, {:env, "OPTIONAL_GENERATED"}, %Postgrex.INET{address: {3, 3, 3, 3}}}
    end
  end
end
