defmodule Domain.Repo.FilterTest do
  use ExUnit.Case, async: true
  import Domain.Repo.Filter
  import Ecto.Query
  alias Domain.Repo.Filter

  describe "build_dynamic/4" do
    test "constructs a dynamic filter" do
      filters = %{
        name: %Filter{
          type: :string,
          name: :name,
          fun: fn :queryable, value ->
            {:updated_queryable, dynamic([binding: binding], binding.name == ^value)}
          end
        }
      }

      assert {queryable, dynamic} = build_dynamic(:queryable, [name: "name"], filters, nil)
      assert queryable == :updated_queryable
      assert inspect(dynamic) == ~s|dynamic([binding: binding], binding.name == ^"name")|
    end

    test "constructs a binary dynamic filter" do
      queryable = Domain.Account.Query.all()

      filters = %{
        bool: %Filter{
          type: :boolean,
          name: :bool,
          fun: fn queryable ->
            {queryable, dynamic([accounts: accounts], is_nil(accounts.disabled_at))}
          end
        }
      }

      assert {queryable, dynamic} = build_dynamic(queryable, [bool: true], filters, nil)

      assert queryable
             |> where(^dynamic)
             |> inspect() == """
             #Ecto.Query<from a0 in Domain.Account,\
              as: :accounts,\
              where: is_nil(a0.disabled_at)>\
             """

      assert {queryable, dynamic} = build_dynamic(queryable, [bool: false], filters, nil)

      assert queryable
             |> where(^dynamic)
             |> inspect() == """
             #Ecto.Query<from a0 in Domain.Account,\
              as: :accounts,\
              where: not is_nil(a0.disabled_at)>\
             """
    end

    # test "constructs a binary range filter" do
    # test "constructs a binary list filter" do

    test "constructs a dynamic with :or operator" do
      filters = %{
        name: %Filter{
          type: :string,
          name: :name,
          fun: fn queryable, value ->
            {queryable, dynamic([accounts: accounts], accounts.name == ^value)}
          end
        }
      }

      filter = [{:or, [[name: "name1"], [name: "name2"]]}]
      assert {:queryable, dynamic} = build_dynamic(:queryable, filter, filters, nil)

      assert Domain.Account.Query.all()
             |> where(^dynamic)
             |> inspect() == """
             #Ecto.Query<from a0 in Domain.Account,\
              as: :accounts,\
              where: a0.name == ^"name1" or a0.name == ^"name2">\
             """
    end

    test "constructs a dynamic with :and operator" do
      filters = %{
        name: %Filter{
          type: :string,
          name: :name,
          fun: fn queryable, value ->
            {queryable, dynamic([accounts: accounts], accounts.name == ^value)}
          end
        }
      }

      filter = [{:and, [[name: "name1"], [name: "name2"]]}]
      assert {:queryable, dynamic} = build_dynamic(:queryable, filter, filters, nil)

      assert Domain.Account.Query.all()
             |> where(^dynamic)
             |> inspect() == """
             #Ecto.Query<from a0 in Domain.Account,\
              as: :accounts,\
              where: a0.name == ^"name1" and a0.name == ^"name2">\
             """
    end
  end

  describe "validate_value/2" do
    test "returns :ok when value type is valid" do
      for {type, value} <- [
            {{:string, :email}, "foo@example.com"},
            {{:string, :phone_number}, "+15671112233"},
            {{:string, :uuid}, Ecto.UUID.generate()},
            {:list, ["a", "b"], "a"},
            {:list, ["a", "b"], "b"},
            {{:range, :datetime}, %Filter.Range{from: DateTime.utc_now()}},
            {{:range, :datetime}, %Filter.Range{to: DateTime.utc_now()}},
            {{:range, :datetime},
             %Filter.Range{from: DateTime.utc_now(), to: DateTime.utc_now()}},
            {:string, "string"},
            {:boolean, true},
            {:boolean, false},
            {:integer, -100},
            {:integer, 100},
            {:number, 100.1},
            {:number, -100.1},
            {:date, Date.utc_today()},
            {:time, Time.new!(23, 59, 59, 999_999)},
            {:datetime, DateTime.utc_now()},
            {:datetime, NaiveDateTime.utc_now()}
          ] do
        assert validate_value(%Filter{type: type}, value) == :ok
      end

      filter = %Filter{
        type: {:string, :uuid}
      }

      assert validate_value(filter, Ecto.UUID.generate()) == :ok
    end

    test "validates that value is whitelisted" do
      filter = %Filter{
        type: :string,
        values: [{"Foo", "foo"}, {"Bar", "bar"}]
      }

      assert validate_value(filter, "foo") == :ok
      assert validate_value(filter, "bar") == :ok

      assert validate_value(filter, "baz") ==
               {:error, {:invalid_value, values: filter.values, value: "baz"}}
    end

    test "validates that all values are whitelisted" do
      filter = %Filter{
        type: {:list, :string},
        values: [{"Foo", "foo"}, {"Bar", "bar"}]
      }

      assert validate_value(filter, ["foo", "bar"]) == :ok

      assert validate_value(filter, ["foo", "baz"]) ==
               {:error, {:invalid_value, values: filter.values, value: ["foo", "baz"]}}
    end

    test "returns error when type is invalid" do
      for {type, value} <- [
            {:string, 100},
            {{:string, :uuid}, "invalid"},
            {:list, ["a", "b"], "c"},
            {:list, ["a", "b"], nil},
            {{:range, :datetime}, %Filter.Range{}},
            {{:range, :datetime}, %Filter.Range{from: Date.utc_today()}},
            {{:range, :datetime}, %Filter.Range{to: Date.utc_today()}},
            {:boolean, "true"},
            {:integer, 100.1},
            {:number, "100.1"},
            {:date, false},
            {:time, false},
            {:datetime, false}
          ] do
        assert validate_value(%Filter{type: type}, value) ==
                 {:error, {:invalid_type, type: type, value: value}}
      end
    end
  end
end
