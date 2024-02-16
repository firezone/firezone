defmodule Web.SignIn.SuccessTest do
  use Web.ConnCase, async: true

  setup do
    account = Fixtures.Accounts.create_account()

    %{account: account}
  end

  test "redirects to deep link URL", %{
    account: account,
    conn: conn
  } do
    query_params = %{
      account_name: "account_name",
      account_slug: "account_slug",
      actor_name: "actor_name",
      fragment: "fragment",
      identity_provider_identifier: "identifier",
      state: "state"
    }

    {:ok, lv, html} =
      conn
      |> live(~p"/#{account}/signin_success?#{query_params}")

    assert html =~ "success"
    assert html =~ "close this window"

    sorted_query_params =
      query_params
      |> Map.to_list()
      |> Enum.sort()
      |> URI.encode_query()

    assert_redirect(
      lv,
      "firezone-fd0020211111://handle_client_sign_in_callback?#{sorted_query_params}",
      1000
    )
  end
end
