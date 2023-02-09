defmodule FzHttp.Config.CasterTest do
  use ExUnit.Case, async: true
  import FzHttp.Config.Caster

  describe "cast/2" do
    test "casts a binary to an array of integers" do
      assert cast("1,2,3", {:array, ",", :integer}) == {:ok, [1, 2, 3]}
    end

    test "casts a binary to an embed" do
      assert cast("{\"foo\": \"bar\"}", :embed) == {:ok, %{"foo" => "bar"}}
    end

    test "casts a binary to an array of embeds" do
      assert cast("[{\"foo\": \"bar\"}]", {:json_array, :embed}) == {:ok, [%{"foo" => "bar"}]}
    end

    test "casts a binary to a map" do
      assert cast("{\"foo\": \"bar\"}", :map) == {:ok, %{"foo" => "bar"}}
    end

    test "casts a binary to boolean" do
      assert cast("true", :boolean) == {:ok, true}
      assert cast("false", :boolean) == {:ok, false}
      assert cast("", :boolean) == {:ok, nil}
    end

    test "casts a binary to integer" do
      assert cast("1", :integer) == {:ok, 1}
      assert cast("12345", :integer) == {:ok, 12345}
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
      assert cast("invalid integer", :integer) == {:error, "can not be cast to an integer"}

      assert cast("123invalid integer", :integer) ==
               {:error,
                "can not be cast to an integer, " <>
                  "got a reminder invalid integer after an integer value 123"}
    end

    test "raises when JSON is not valid" do
      assert cast("invalid json", :embed) ==
               {:error, %Jason.DecodeError{position: 0, token: nil, data: "invalid json"}}

      assert cast("invalid json", {:json_array, :embed}) ==
               {:error, %Jason.DecodeError{position: 0, token: nil, data: "invalid json"}}
    end
  end
end
