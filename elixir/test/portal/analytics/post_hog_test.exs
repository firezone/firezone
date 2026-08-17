defmodule Portal.Analytics.PostHogTest do
  use ExUnit.Case, async: true

  alias Portal.Analytics.PostHog

  setup do
    Portal.Config.put_env_override(:portal, PostHog,
      enabled: true,
      endpoint: "https://posthog.test/i/v0/e/",
      project_api_key: "phc_test",
      req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
    )

    :ok
  end

  test "posts events to the configured capture endpoint" do
    test_pid = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posthog_request, conn, JSON.decode!(body)})
      Req.Test.json(conn, %{"status" => "ok"})
    end)

    assert :ok =
             PostHog.capture("Portal Attribution Received", "anonymous-id", %{
               "$process_person_profile" => false,
               "website_path" => "/pricing"
             })

    assert_receive {:posthog_request, conn, body}
    assert conn.method == "POST"
    assert conn.request_path == "/i/v0/e/"
    assert body["api_key"] == "phc_test"
    assert body["event"] == "Portal Attribution Received"
    assert body["properties"]["distinct_id"] == "anonymous-id"
    assert body["properties"]["website_path"] == "/pricing"
    assert body["properties"]["$process_person_profile"] == false
  end

  test "builds an identify event that aliases the website visitor to the actor" do
    actor = %Portal.Actor{
      id: "c69036ab-96d0-4534-86b6-f1af9092015c",
      email: "ada@example.com",
      name: "Ada Lovelace",
      type: :account_admin_user
    }

    account = %Portal.Account{
      id: "a649f7b5-ef17-45a9-8983-48e02d441e0e",
      name: "Analytical Engines",
      slug: "analytical-engines"
    }

    attribution = %{
      "distinct_id" => "7d2ed047-64d3-41f9-9a41-ac2c9b92e761",
      "source" => "www.firezone.dev",
      "website_path" => "/pricing"
    }

    actor_id = actor.id

    assert {"$identify", ^actor_id, properties} =
             PostHog.identify_event(actor, account, attribution)

    assert properties["$anon_distinct_id"] == attribution["distinct_id"]
    assert properties["$process_person_profile"] == true
    assert properties["$set"]["email"] == actor.email
    assert properties["$set"]["account_id"] == account.id
    assert properties["$set_once"]["initial_website_path"] == "/pricing"
  end
end
