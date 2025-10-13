defmodule Domain.Config.CasterTest do
  use ExUnit.Case, async: true
  import Domain.Config.Caster

  describe "cast/2" do
    test "casts a binary to an array of integers" do
      assert cast("1,2,3", {:array, ",", :integer}) == {:ok, [1, 2, 3]}
    end

    test "casts a binary to an embed" do
      assert cast(~s|{"foo": "bar"}|, :embed) == {:ok, %{"foo" => "bar"}}
    end

    test "casts a binary to an array of embeds" do
      assert cast(~s|[{"foo": "bar"}]|, {:json_array, :embed}) == {:ok, [%{"foo" => "bar"}]}
    end

    test "casts a binary to a map" do
      assert cast(~s|{"foo": "bar"}|, :map) == {:ok, %{"foo" => "bar"}}
    end

    test "casts a binary to boolean" do
      assert cast("true", :boolean) == {:ok, true}
      assert cast("false", :boolean) == {:ok, false}
      assert cast("", :boolean) == {:ok, nil}
    end

    test "casts a binary to integer" do
      assert cast("1", :integer) == {:ok, 1}
      assert cast("12345", :integer) == {:ok, 12_345}
    end

    test "keeps original non-binary value even if doesn't match the type" do
      assert cast(1, :integer) == {:ok, 1}
      assert cast(1, :boolean) == {:ok, 1}
      assert cast(1, {:array, ",", :integer}) == {:ok, 1}
      assert cast(1, :embed) == {:ok, 1}
      assert cast(1, {:json_array, :embed}) == {:ok, 1}
      assert cast(1, :map) == {:ok, 1}
    end

    test "raises when integer is not valid" do
      assert cast("invalid integer", :integer) == {:error, "cannot be cast to an integer"}

      assert cast("123invalid integer", :integer) ==
               {:error,
                "cannot be cast to an integer, " <>
                  "got a reminder invalid integer after an integer value 123"}
    end

    test "raises when JSON is not valid" do
      assert {:error, {:invalid_byte, _offset, _byte}} = cast("invalid json", :embed)
      assert {:error, {:invalid_byte, _offset, _byte}} = cast("invalid json", {:json_array, :embed})
    end
  end
end
