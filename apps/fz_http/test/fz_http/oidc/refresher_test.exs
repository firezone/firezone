defmodule FzHttp.OIDC.RefresherTest do
  use FzHttp.DataCase, async: true

  import Mox

  alias FzHttp.{OIDC.Refresher, Repo}

  setup :create_user

  setup %{user: user} do
    conn =
      Repo.insert!(%FzHttp.OIDC.Connection{
        user_id: user.id,
        provider: "test",
        refresh_token: "REFRESH_TOKEN"
      })

    {:ok, conn: conn}
  end

  describe "refresh failed" do
    setup do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ ->
        {:error, :fetch_tokens, "TEST_ERROR"}
      end)

      :ok
    end

    test "disable user", %{user: user, conn: conn} do
      Refresher.refresh(user.id)
      user = Repo.reload(user)
      conn = Repo.reload(conn)

      refute user.allowed_to_connect
      assert %{"error" => _} = conn.refresh_response
    end
  end

  describe "refresh succeeded" do
    setup do
      expect(OpenIDConnect.Mock, :fetch_tokens, fn _, _ ->
        {:ok, %{data: "success"}}
      end)

      :ok
    end

    test "does not change user", %{user: user, conn: conn} do
      Refresher.refresh(user.id)
      user = Repo.reload(user)
      conn = Repo.reload(conn)

      assert user.allowed_to_connect
      refute match?(%{"error" => _}, conn.refresh_response)
    end
  end
end
