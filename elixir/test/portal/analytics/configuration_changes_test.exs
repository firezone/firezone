defmodule Portal.Analytics.ConfigurationChangesTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures

  alias Portal.Analytics.ConfigurationChanges
  alias Portal.Analytics.PostHog

  @account_id "a649f7b5-ef17-45a9-8983-48e02d441e0e"
  @actor_id "c69036ab-96d0-4534-86b6-f1af9092015c"
  @accounts %{@account_id => %{name: "Analytical Engines", slug: "analytical-engines"}}
  @browser "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"

  describe "events/1" do
    test "builds an event with the object, operation and source" do
      assert [event] = ConfigurationChanges.events([entry()], @accounts)

      assert event["event"] == "Configuration Changed"
      assert event["timestamp"] == "2026-10-19T12:00:00.000000Z"

      assert event["properties"] == %{
               "distinct_id" => @actor_id,
               "$groups" => %{"account" => @account_id},
               "account_name" => "Analytical Engines",
               "account_slug" => "analytical-engines",
               "object" => "resource",
               "operation" => "insert",
               "source" => "portal"
             }
    end

    test "infers the source from the actor type and user agent" do
      sources =
        for {actor_type, user_agent} <- [
              {"account_admin_user", @browser},
              {"api_client", "Terraform/1.9.0 terraform-provider-firezone/0.4.0"},
              {"api_client", "curl/8.7.1"},
              {"api_client", nil},
              {"account_admin_user", "node"}
            ] do
          [event] =
            ConfigurationChanges.events([
              entry(subject: %{"actor_id" => @actor_id, "actor_type" => actor_type, "user_agent" => user_agent})
            ], @accounts)

          event["properties"]["source"]
        end

      assert sources == ["portal", "terraform", "api", "api", "other"]
    end

    test "names provider tables by kind and type" do
      objects =
        for table <- ~w[okta_directories google_auth_providers datadog_log_sinks intune_posture_providers] do
          [%{"properties" => properties}] = ConfigurationChanges.events([entry(object: table)], @accounts)
          {properties["object"], properties["object_type"]}
        end

      assert objects == [
               {"directory", "okta"},
               {"auth_provider", "google"},
               {"log_sink", "datadog"},
               {"posture_provider", "intune"}
             ]
    end

    test "skips changes without an actor and objects that aren't configuration" do
      assert ConfigurationChanges.events([
               entry(subject: nil),
               entry(object: "memberships"),
               entry(object: "devices"),
               entry(object: "one_time_passcodes")
             ], @accounts) == []
    end

    test "never sends object data" do
      payload =
        [entry(after: %{"name" => "Secret Resource", "address" => "secret.example.com"})]
        |> ConfigurationChanges.events(@accounts)
        |> JSON.encode!()

      refute payload =~ "Secret Resource"
      refute payload =~ "secret.example.com"
      refute payload =~ @browser
    end

    test "maps the same write to the same event UUID" do
      [first] = ConfigurationChanges.events([entry(lsn: 100)], @accounts)
      [replayed] = ConfigurationChanges.events([entry(lsn: 100)], @accounts)
      [other] = ConfigurationChanges.events([entry(lsn: 101)], @accounts)

      assert first["uuid"] == replayed["uuid"]
      assert first["uuid"] != other["uuid"]
    end
  end

  describe "capture/1" do
    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:posthog, conn.request_path, JSON.decode!(body)})
        Req.Test.json(conn, %{"status" => "Ok"})
      end)

      :ok
    end

    test "sends the events to the batch endpoint with the account's name and slug" do
      account = account_fixture()
      put_posthog_config(enabled: true)

      assert :ok =
               ConfigurationChanges.capture([
                 entry(account_id: account.id),
                 entry(account_id: account.id, subject: nil)
               ])

      assert_receive {:posthog, "/batch/", %{"batch" => [%{"properties" => properties}]}}
      assert properties["account_name"] == account.name
      assert properties["account_slug"] == account.slug
    end

    test "sends changes of a deleted account without its name and slug" do
      put_posthog_config(enabled: true)

      assert :ok = ConfigurationChanges.capture([entry(account_id: Ecto.UUID.generate())])

      assert_receive {:posthog, "/batch/", %{"batch" => [%{"properties" => properties}]}}
      assert properties["account_name"] == nil
      assert properties["account_slug"] == nil
    end

    test "sends nothing when PostHog is disabled" do
      put_posthog_config(enabled: false)

      assert :ok = ConfigurationChanges.capture([entry()])

      refute_receive {:posthog, _path, _body}, 200
    end
  end

  defp entry(attrs \\ []) do
    Map.merge(
      %{
        timestamp: ~U[2026-10-19 12:00:00.000000Z],
        lsn: 100,
        object: "resources",
        operation: :insert,
        account_id: @account_id,
        before: nil,
        after: %{"id" => Ecto.UUID.generate()},
        subject: %{
          "actor_id" => @actor_id,
          "actor_type" => "account_admin_user",
          "actor_email" => "ada@example.com",
          "user_agent" => @browser
        }
      },
      Map.new(attrs)
    )
  end

  defp put_posthog_config(opts) do
    Portal.Config.put_env_override(
      :portal,
      PostHog,
      Keyword.merge(
        [
          host: "https://posthog.test",
          project_api_key: "phc_test",
          req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
        ],
        opts
      )
    )
  end
end
