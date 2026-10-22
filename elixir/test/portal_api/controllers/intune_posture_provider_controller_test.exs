defmodule PortalAPI.IntunePostureProviderControllerTest do
  use PortalAPI.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.ActorFixtures
  import Portal.DevicePostureFixtures
  import Portal.IntuneFixtures

  setup do
    account = device_posture_account_fixture()
    actor = api_client_fixture(account: account)
    %{account: account, actor: actor}
  end

  test "requires authorization", %{conn: conn} do
    assert conn |> get("/intune_posture_providers") |> json_response(401)
  end

  test "lists every provider of the account", %{conn: conn, actor: actor} do
    first = intune_posture_provider_fixture(account: actor.account)
    second = intune_posture_provider_fixture(account: actor.account)
    intune_posture_provider_fixture()

    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_posture_providers")
      |> json_response(200)
      |> Map.fetch!("data")

    assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([first.id, second.id])
    assert Enum.all?(data, &(&1["type"] == "intune"))
  end

  test "returns a provider and its sync state", %{conn: conn, actor: actor} do
    provider = intune_posture_provider_fixture(account: actor.account)

    data =
      conn
      |> authorize_conn(actor)
      |> get("/intune_posture_providers/#{provider.id}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["id"] == provider.id
    assert data["tenant_id"] == provider.tenant_id
    assert data["type"] == "intune"
    assert data["is_verified"]
  end

  test "does not return another account's provider", %{conn: conn, actor: actor} do
    provider = intune_posture_provider_fixture()

    assert conn
           |> authorize_conn(actor)
           |> get("/intune_posture_providers/#{provider.id}")
           |> json_response(404)
  end

  describe "update/2" do
    test "renames a provider", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      data =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"name" => "Renamed"}
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["name"] == "Renamed"
      assert Repo.get_by!(Portal.PostureProvider, id: provider.id).name == "Renamed"
    end

    test "accepts PATCH", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      assert conn
             |> authorize_conn(actor)
             |> put_req_header("content-type", "application/json")
             |> patch("/intune_posture_providers/#{provider.id}", %{
               "intune_posture_provider" => %{"name" => "Patched"}
             })
             |> json_response(200)
             |> get_in(["data", "name"]) == "Patched"
    end

    test "refuses a name another provider uses", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)
      other = intune_posture_provider_fixture(account: actor.account)

      body =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"name" => other.posture_provider.name}
        })
        |> json_response(422)

      assert body["validation_errors"] == %{
               "name" => ["A posture provider with this name already exists."]
             }
    end

    test "refuses a blank name", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      body =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"name" => ""}
        })
        |> json_response(422)

      assert body["validation_errors"] == %{"name" => ["should be at least 1 character(s)"]}
    end

    test "disables a provider", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      data =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"is_disabled" => true}
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["is_disabled"]
      assert data["disabled_reason"] == "Disabled by admin"
      refute_enqueued(worker: Portal.Intune.Sync)
    end

    test "enables a verified provider, clears its sync error and queues a sync", %{
      conn: conn,
      actor: actor
    } do
      provider =
        intune_posture_provider_fixture(
          account: actor.account,
          is_disabled: true,
          disabled_reason: "Sync error",
          errored_at: DateTime.utc_now(),
          error_message: "boom",
          error_email_count: 2
        )

      data =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"is_disabled" => false}
        })
        |> json_response(200)
        |> Map.fetch!("data")

      refute data["is_disabled"]
      assert data["disabled_reason"] == nil
      assert data["error_message"] == nil
      assert data["errored_at"] == nil
      assert Repo.get_by!(Portal.Intune.PostureProvider, id: provider.id).error_email_count == 0

      assert_enqueued(
        worker: Portal.Intune.Sync,
        args: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}
      )
    end

    test "refuses to enable an unverified provider", %{conn: conn, actor: actor} do
      provider =
        intune_posture_provider_fixture(
          account: actor.account,
          is_verified: false,
          is_disabled: true,
          disabled_reason: "Sync error"
        )

      body =
        conn
        |> authorize_conn(actor)
        |> put_req_header("content-type", "application/json")
        |> put("/intune_posture_providers/#{provider.id}", %{
          "intune_posture_provider" => %{"is_disabled" => false}
        })
        |> json_response(422)

      assert %{"is_disabled" => [message]} = body["validation_errors"]
      assert message =~ "must be verified"
      assert Repo.get_by!(Portal.Intune.PostureProvider, id: provider.id).is_disabled
      refute_enqueued(worker: Portal.Intune.Sync)
    end

    test "requires the request body wrapper", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      assert conn
             |> authorize_conn(actor)
             |> put_req_header("content-type", "application/json")
             |> put("/intune_posture_providers/#{provider.id}", %{"name" => "Renamed"})
             |> json_response(400)
    end

    test "does not update another account's provider", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture()

      assert conn
             |> authorize_conn(actor)
             |> put_req_header("content-type", "application/json")
             |> put("/intune_posture_providers/#{provider.id}", %{
               "intune_posture_provider" => %{"name" => "Renamed"}
             })
             |> json_response(404)
    end

    test "requires the posture_providers:write scope", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      assert %{"detail" => detail} =
               conn
               |> authorize_conn(actor, ["posture_providers:read"])
               |> put_req_header("content-type", "application/json")
               |> put("/intune_posture_providers/#{provider.id}", %{
                 "intune_posture_provider" => %{"name" => "Renamed"}
               })
               |> json_response(403)

      assert detail =~ "posture_providers:write"
    end
  end

  describe "delete/2" do
    test "deletes a provider and returns it", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture(account: actor.account)

      data =
        conn
        |> authorize_conn(actor)
        |> delete("/intune_posture_providers/#{provider.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["id"] == provider.id
      assert data["name"] == provider.posture_provider.name
      refute Repo.get_by(Portal.PostureProvider, id: provider.id)
      refute Repo.get_by(Portal.Intune.PostureProvider, id: provider.id)
    end

    test "does not delete another account's provider", %{conn: conn, actor: actor} do
      provider = intune_posture_provider_fixture()

      assert conn
             |> authorize_conn(actor)
             |> delete("/intune_posture_providers/#{provider.id}")
             |> json_response(404)

      assert Repo.get_by(Portal.Intune.PostureProvider, id: provider.id)
    end
  end
end
