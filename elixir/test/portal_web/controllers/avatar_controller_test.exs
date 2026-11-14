defmodule PortalWeb.AvatarControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AvatarStorageHelpers
  import Portal.EntraDirectoryFixtures
  import Portal.IdentityFixtures

  setup do
    account = account_fixture()
    admin = admin_actor_fixture(account: account)
    directory = entra_directory_fixture(account: account)
    identity = directory_identity_fixture(directory: directory, avatar_etag: "etag-1")
    store = stub_avatar_storage()
    put_blob(store, blob_name(identity), png(), "text/html")

    %{account: account, admin: admin, identity: identity, store: store}
  end

  test "serves the photo with a content type taken from its bytes", %{conn: conn} = ctx do
    conn = conn |> authorize_conn(ctx.admin) |> get(~p"/#{ctx.account}/avatars/#{ctx.identity.id}")

    assert response(conn, 200) == png()
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
  end

  test "returns 404 for a blob that is not an image", %{conn: conn} = ctx do
    put_blob(ctx.store, blob_name(ctx.identity), "<script>alert(1)</script>")

    conn = conn |> authorize_conn(ctx.admin) |> get(~p"/#{ctx.account}/avatars/#{ctx.identity.id}")

    assert response(conn, 404)
  end

  test "returns 404 for an identity without a photo", %{conn: conn} = ctx do
    Portal.Repo.update_all(Portal.ExternalIdentity, set: [avatar_etag: nil])

    conn = conn |> authorize_conn(ctx.admin) |> get(~p"/#{ctx.account}/avatars/#{ctx.identity.id}")

    assert response(conn, 404)
  end

  test "returns 404 for an identity of another account", %{conn: conn} = ctx do
    other_account = account_fixture()
    other_admin = admin_actor_fixture(account: other_account)

    conn = conn |> authorize_conn(other_admin) |> get(~p"/#{other_account}/avatars/#{ctx.identity.id}")

    assert response(conn, 404)
  end

  test "returns 404 for an invalid id", %{conn: conn} = ctx do
    conn = conn |> authorize_conn(ctx.admin) |> get(~p"/#{ctx.account}/avatars/not-a-uuid")

    assert response(conn, 404)
  end

  test "requires a signed-in admin", %{conn: conn} = ctx do
    conn = get(conn, ~p"/#{ctx.account}/avatars/#{ctx.identity.id}")

    assert redirected_to(conn) =~ ~p"/#{ctx.account}"
  end
end
