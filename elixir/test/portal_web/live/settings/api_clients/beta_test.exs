defmodule PortalWeb.Live.Settings.ApiClients.BetaTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
    path = ~p"/#{account}/settings/api_clients/beta"

    assert live(conn, path) ==
             {:error,
              {:redirect,
               %{
                 to: ~p"/#{account}?#{%{redirect_to: path}}",
                 flash: %{"error" => "You must sign in to access that page."}
               }}}
  end

  test "redirects to API client index when feature enabled", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    assert {:error, {:live_redirect, %{to: path, flash: _}}} =
             conn
             |> authorize_conn(actor)
             |> live(~p"/#{account}/settings/api_clients/beta")

    assert path == ~p"/#{account}/settings/api_clients"
  end

  test "renders breadcrumbs item", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account = update_account(account, %{features: %{rest_api: false}})

    {:ok, _lv, html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/beta")

    assert item = html |> Floki.parse_fragment!() |> Floki.find("[aria-label='Breadcrumb']")
    breadcrumbs = String.trim(Floki.text(item))
    assert breadcrumbs =~ "API Clients"
    assert breadcrumbs =~ "Beta"
  end

  test "sends beta request email", %{
    account: account,
    actor: actor,
    conn: conn
  } do
    account =
      update_account(account, %{
        features: %{
          rest_api: false,
          traffic_filters: true,
          policy_conditions: true,
          idp_sync: true
        }
      })

    {:ok, lv, _html} =
      conn
      |> authorize_conn(actor)
      |> live(~p"/#{account}/settings/api_clients/beta")

    assert lv
           |> element("#beta-request")
           |> render_click()
           |> Floki.parse_fragment!()
           |> Floki.find(".flash-info")
           |> element_to_text() =~ "request to join"

    assert_email_queued(fn email ->
      assert email.subject == "REST API Beta Request - #{account.id}"
      assert email.text_body =~ "REST API Beta Request"
      assert email.text_body =~ "#{account.id}"
      assert email.text_body =~ "#{actor.id}"
    end)
  end

  defp collect_queued_emails do
    import Ecto.Query

    from(e in Portal.OutboundEmail, order_by: [asc: e.inserted_at])
    |> Portal.Repo.all()
    |> Enum.map(fn entry ->
      %{
        subject: entry.request["subject"],
        text_body: entry.request["text_body"],
        html_body: entry.request["html_body"],
        to: Enum.map(entry.request["to"] || [], fn %{"name" => n, "address" => a} -> {n, a} end),
        bcc: Enum.map(entry.request["bcc"] || [], fn %{"name" => n, "address" => a} -> {n, a} end)
      }
    end)
  end

  defp assert_email_queued(fun) do
    [email | _] = collect_queued_emails()
    fun.(email)
  end
end
