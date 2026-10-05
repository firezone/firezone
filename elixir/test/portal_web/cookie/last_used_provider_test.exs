defmodule PortalWeb.Cookie.LastUsedProviderTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie.LastUsedProvider

  @cookie_key "last_used_provider"

  defp recycle_conn(conn) do
    build_conn()
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.put_req_cookie(@cookie_key, conn.resp_cookies[@cookie_key].value)
  end

  test "stores and retrieves the provider id", %{conn: conn} do
    id = Ecto.UUID.generate()

    conn = conn |> LastUsedProvider.put(id) |> recycle_conn()

    assert LastUsedProvider.fetch(conn) == id
  end

  test "keeps only the most recent provider id", %{conn: conn} do
    id = Ecto.UUID.generate()

    conn =
      conn
      |> LastUsedProvider.put(Ecto.UUID.generate())
      |> recycle_conn()
      |> LastUsedProvider.put(id)
      |> recycle_conn()

    assert LastUsedProvider.fetch(conn) == id
  end

  test "returns nil when the cookie is missing", %{conn: conn} do
    assert LastUsedProvider.fetch(conn) == nil
  end

  test "returns nil when the cookie is not signed", %{conn: conn} do
    conn = Plug.Test.put_req_cookie(conn, @cookie_key, Ecto.UUID.generate())

    assert LastUsedProvider.fetch(conn) == nil
  end
end
