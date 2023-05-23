# defmodule Domain.Auth.OIDC.RefresherTest do
#   use Domain.DataCase, async: true
#   alias Domain.Auth.OIDC.Refresher
#   alias Domain.UsersFixtures

#   setup do
#     user = UsersFixtures.create_user_with_role(:account_admin_user)
#     {bypass, [provider_attrs]} = Domain.ConfigFixtures.start_openid_providers(["google"])

#     conn =
#       Repo.insert!(%Domain.Auth.OIDC.Connection{
#         user_id: user.id,
#         provider: "google",
#         refresh_token: "REFRESH_TOKEN"
#       })

#     %{user: user, conn: conn, bypass: bypass, provider_attrs: provider_attrs}
#   end

#   describe "refresh failed" do
#     test "disable user", %{user: user, conn: conn, bypass: bypass} do
#       Domain.ConfigFixtures.expect_refresh_token_failure(bypass)

#       assert Refresher.refresh(user.id) == {:stop, :shutdown, user.id}
#       user = Repo.reload(user)
#       assert user.disabled_at

#       conn = Repo.reload(conn)
#       assert %{"error" => _} = conn.refresh_response
#     end
#   end

#   describe "refresh succeeded" do
#     test "does not change user", %{user: user, conn: conn, bypass: bypass} do
#       Domain.ConfigFixtures.expect_refresh_token(bypass)

#       assert Refresher.refresh(user.id) == {:stop, :shutdown, user.id}
#       user = Repo.reload(user)
#       refute user.disabled_at

#       conn = Repo.reload(conn)
#       refute match?(%{"error" => _}, conn.refresh_response)
#     end
#   end
# end
