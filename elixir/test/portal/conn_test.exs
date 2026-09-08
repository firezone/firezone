defmodule Portal.ConnTest do
  use ExUnit.Case, async: true

  alias Portal.Conn

  setup do
    %{conn: Plug.Test.conn(:post, "/", "") |> Plug.Conn.assign(:current, true)}
  end

  test "returns the function result", %{conn: conn} do
    assert Conn.wrap_errors(conn, &{:ok, &1}) == {:ok, conn}
  end

  for kind <- [:error, :exit, :throw] do
    test "wraps a #{kind} with the conn it was given", %{conn: conn} do
      error =
        assert_raise Plug.Conn.WrapperError, fn ->
          Conn.wrap_errors(conn, fn _conn -> fail(unquote(kind)) end)
        end

      assert error.conn.assigns.current
      assert error.kind == unquote(kind)
      assert error.reason == fail_reason(unquote(kind))
    end
  end

  test "keeps the conn of an error that was already wrapped", %{conn: conn} do
    inner = Plug.Conn.assign(conn, :inner, true)

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        Conn.wrap_errors(conn, fn _conn ->
          Conn.wrap_errors(inner, fn _conn -> raise "boom" end)
        end)
      end

    assert error.conn.assigns.inner
  end

  defp fail(:error), do: raise("boom")
  defp fail(:exit), do: exit(:boom)
  defp fail(:throw), do: throw(:boom)

  defp fail_reason(:error), do: %RuntimeError{message: "boom"}
  defp fail_reason(_kind), do: :boom
end
