defmodule Domain.InstrumentationTest do
  use Domain.DataCase, async: true
  import Domain.Instrumentation
  alias Domain.Mocks.GoogleCloudPlatform

  describe "create_remote_log_sink/1" do
    test "returns an error if feature is disabled" do
      client = Fixtures.Clients.create_client()

      Domain.Config.put_env_override(Domain.Instrumentation, client_logs_enabled: false)

      assert create_remote_log_sink(client, "acct_slug", "john_doe") == {:error, :disabled}
    end

    test "returns a signed URL" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_sign_blob_endpoint(bypass, "foo")

      client = Fixtures.Clients.create_client()
      {:ok, actor} = Domain.Actors.fetch_actor_by_id(client.actor_id)
      {:ok, account} = Domain.Accounts.fetch_account_by_id(actor.account_id)

      actor_name =
        actor.name
        |> String.downcase()
        |> String.replace(" ", "_")
        |> String.replace(~r/[^a-zA-Z0-9_-]/iu, "")

      assert {:ok, signed_url} = create_remote_log_sink(client, actor_name, account.slug)

      assert signed_uri = URI.parse(signed_url)
      assert signed_uri.scheme == "https"
      assert signed_uri.host == "storage.googleapis.com"

      assert String.starts_with?(
               signed_uri.path,
               "/logs/clients/#{account.slug}/#{actor_name}/#{client.id}/"
             )

      assert String.ends_with?(signed_uri.path, ".json")
    end
  end
end
