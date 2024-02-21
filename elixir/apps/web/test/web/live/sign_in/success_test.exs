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
      "actor_name" => "actor_name",
      "fragment" => "fragment",
      "identity_provider_identifier" => "identifier",
      "state" => "state"
    }

    {:ok, lv, html} =
      conn
      |> live(~p"/#{account}/sign_in/success?#{query_params}")

    assert html =~ "success"
    assert html =~ "close this window"

    expected_query_params =
      query_params
      |> Map.put("account_name", account.name)
      |> Map.put("account_slug", account.slug)

    {path, _flash} = assert_redirect(lv, 500)
    uri = URI.parse(path)
    assert URI.decode_query(uri.query) == expected_query_params
  end
end
