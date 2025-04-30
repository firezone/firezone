defmodule Domain.Events.Hooks.AccountsTest do
  use ExUnit.Case, async: true
  import Domain.Events.Hooks.Accounts

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == insert(data)
    end
  end

  describe "update/2" do
    test "returns :ok", %{old_data: old_data, data: data} do
      assert :ok == update(old_data, data)
    end
  end

  describe "delete/1" do
    test "returns :ok", %{data: data} do
      assert :ok == delete(data)
    end
  end
end
