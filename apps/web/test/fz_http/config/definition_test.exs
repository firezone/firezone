defmodule FzHttp.Config.DefinitionTest do
  use ExUnit.Case, async: true
  import FzHttp.Config.Definition

  defmodule InvalidDefinitions do
    use FzHttp.Config.Definition

    defconfig(:required, Types.IP, foo: :bar)
  end

  defmodule Definitions do
    use FzHttp.Config.Definition

    defconfig(:required, Types.IP)

    defconfig(:optional, Types.IP, default: "0.0.0.0")

    defconfig(:with_legacy_key, :string, legacy_keys: [{:env, "FOO", "100.0"}])

    defconfig(:with_validation, :integer,
      changeset: fn changeset, key ->
        Ecto.Changeset.validate_number(changeset, key,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 2
        )
      end
    )

    defconfig(:sensitive, :string, sensitive: true)

    defconfig(:with_dump, :map,
      dump: fn value ->
        for {k, v} <- value, do: {k, v}
      end
    )
  end

  describe "__using__/1" do
    test "inserts a function which returns list of defined configs" do
      assert Definitions.configs() == [
               {Definitions, :with_dump},
               {Definitions, :sensitive},
               {Definitions, :with_validation},
               {Definitions, :with_legacy_key},
               {Definitions, :optional},
               {Definitions, :required}
             ]
    end

    test "inserts a function which returns spec of a given config definition" do
      assert Definitions.required() == {Types.IP, []}
      assert Definitions.optional() == {Types.IP, default: "0.0.0.0"}
      assert Definitions.with_legacy_key() == {:string, legacy_keys: [{:env, "FOO", "100.0"}]}
      assert {:integer, changeset: _cb} = Definitions.with_validation()

      assert InvalidDefinitions.required() == {Types.IP, [foo: :bar]}
    end

    test "inserts a function which returns definition doc" do
      assert fetch_doc(FzHttp.Config.Definitions, :default_admin_email) ==
               {:ok, "Primary administrator email.\n"}

      assert fetch_doc(Foo, :bar) ==
               {:error, :module_not_found}
    end
  end

  describe "fetch_spec_and_opts!/2" do
    test "returns spec and opts for a given config definition" do
      assert fetch_spec_and_opts!(Definitions, :required) == {Types.IP, {[], [], [], []}}

      assert fetch_spec_and_opts!(Definitions, :optional) ==
               {Types.IP, {[default: "0.0.0.0"], [], [], []}}

      assert fetch_spec_and_opts!(Definitions, :with_legacy_key) ==
               {:string, {[legacy_keys: [{:env, "FOO", "100.0"}]], [], [], []}}

      assert {:integer, {[], [{:changeset, _cb}], [], []}} =
               fetch_spec_and_opts!(Definitions, :with_validation)

      assert {:map, {[], [], [{:dump, _cb}], []}} = fetch_spec_and_opts!(Definitions, :with_dump)

      assert {:string, {[], [], [], [sensitive: true]}} =
               fetch_spec_and_opts!(Definitions, :sensitive)
    end

    test "raises on invalid opts" do
      assert_raise RuntimeError, "unknown options [foo: :bar] for configuration :required", fn ->
        fetch_spec_and_opts!(InvalidDefinitions, :required)
      end
    end
  end
end
