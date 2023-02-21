defmodule FzHttp.OIDC.RefresherTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.{OIDC.Refresher, Repo}

  setup :create_user

  setup %{user: user} do
    {bypass, [provider_attrs]} = FzHttp.ConfigFixtures.start_openid_providers(["google"])

    conn =
      Repo.insert!(%FzHttp.OIDC.Connection{
        user_id: user.id,
        provider: "google",
        refresh_token: "REFRESH_TOKEN"
      })

    {:ok, conn: conn, bypass: bypass, provider_attrs: provider_attrs}
  end

  describe "refresh failed" do
    test "disable user", %{user: user, conn: conn, bypass: bypass} do
      FzHttp.ConfigFixtures.expect_refresh_token_failure(bypass)

      assert Refresher.refresh(user.id) == {:stop, :shutdown, user.id}
      user = Repo.reload(user)
      assert user.disabled_at

      conn = Repo.reload(conn)
      assert %{"error" => _} = conn.refresh_response
    end
  end

  describe "refresh succeeded" do
    test "does not change user", %{user: user, conn: conn, bypass: bypass} do
      FzHttp.ConfigFixtures.expect_refresh_token(bypass)

      assert Refresher.refresh(user.id) == {:stop, :shutdown, user.id}
      user = Repo.reload(user)
      refute user.disabled_at

      conn = Repo.reload(conn)
      refute match?(%{"error" => _}, conn.refresh_response)
    end
  end
end
