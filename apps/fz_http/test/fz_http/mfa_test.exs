defmodule FzHttp.MFATest do
  use FzHttp.DataCase, async: true

  alias FzHttp.MFA

  setup :create_user

  setup %{user: user} do
    {:ok, method} = create_method(user)

    {:ok, method: method}
  end

  describe "types" do
    test "totp", %{user: user} do
      assert {:ok, _method} = create_method(user, type: :totp)
    end

    test "native", %{user: user} do
      assert {:ok, _method} = create_method(user, type: :native)
    end

    test "portable", %{user: user} do
      assert {:ok, _method} = create_method(user, type: :portable)
    end

    test "fails to create unknown", %{user: user} do
      assert {:error, _changeset} = create_method(user, type: :unknown)
    end
  end

  describe "queries" do
    test "count_distinct_by_user_id", %{user: user} do
      Enum.each(1..5, fn _ -> create_method(user) end)
      assert MFA.count_distinct_by_user_id() == 1
    end

    test "list in descending order", %{user: user} do
      Enum.each(1..5, fn _ -> create_method(user) end)
      methods = MFA.list_methods(user)
      assert methods == Enum.sort_by(methods, & &1.last_used_at, {:desc, DateTime})
    end

    test "get last used method", %{user: user} do
      Enum.each(1..5, fn _ -> create_method(user) end)
      methods = MFA.list_methods(user)
      method = MFA.most_recent_method(user)
      assert method == Enum.max_by(methods, & &1.last_used_at, DateTime)
    end

    test "get nil if no methods are present", %{user: user, method: method} do
      MFA.delete_method(method)
      assert nil == MFA.most_recent_method(user)
    end
  end
end
