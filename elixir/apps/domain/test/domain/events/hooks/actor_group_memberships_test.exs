defmodule Domain.Events.Hooks.ActorGroupMembershipsTest do
  use API.ChannelCase, async: true
  import Domain.Events.Hooks.ActorGroupMemberships
  alias Domain.PubSub

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok" do
      actor_id = "#{Ecto.UUID.generate()}"
      group_id = "#{Ecto.UUID.generate()}"

      data = %{
        "actor_id" => actor_id,
        "group_id" => group_id
      }

      :ok = PubSub.Actor.Memberships.subscribe(actor_id)

      assert :ok == on_insert(data)

      # TODO: WAL
      # Remove this when direct broadcast is implement
      Process.sleep(100)

      assert_receive {:create_membership, ^actor_id, ^group_id}
    end
  end

  describe "update/2" do
    test "returns :ok", %{old_data: old_data, data: data} do
      assert :ok == on_update(old_data, data)
    end
  end

  describe "delete/1" do
    setup do
      account = Fixtures.Accounts.create_account()
      actor_group = Fixtures.Actors.create_group(account: account)
      actor = Fixtures.Actors.create_actor(account: account, type: :account_admin_user)
      Fixtures.Actors.create_membership(account: account, group: actor_group, actor: actor)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      subject = Fixtures.Auth.create_subject(identity: identity)
      client = Fixtures.Clients.create_client(subject: subject)

      resource = Fixtures.Resources.create_resource(account: account)

      policy =
        Fixtures.Policies.create_policy(
          account: account,
          resource: resource,
          actor_group: actor_group
        )

      {:ok, _reply, socket} =
        API.Client.Socket
        |> socket("client:#{client.id}", %{
          opentelemetry_ctx: OpenTelemetry.Ctx.new(),
          opentelemetry_span_ctx: OpenTelemetry.Tracer.start_span("test"),
          client: client,
          subject: subject,
          turn_salt: "test_salt"
        })
        |> subscribe_and_join(API.Client.Channel, "client")

      %{
        account: account,
        actor_group: actor_group,
        actor: actor,
        identity: identity,
        subject: subject,
        client: client,
        resource: resource,
        policy: policy,
        socket: socket
      }
    end

    test "returns :ok" do
      actor_id = "#{Ecto.UUID.generate()}"
      group_id = "#{Ecto.UUID.generate()}"

      data = %{
        "account_id" => "#{Ecto.UUID.generate()}",
        "actor_id" => actor_id,
        "group_id" => group_id
      }

      :ok = PubSub.Actor.Memberships.subscribe(actor_id)

      assert :ok == on_delete(data)
      assert_receive {:delete_membership, ^actor_id, ^group_id}
    end

    test "client channel pushes \"resource_deleted\" when affected membership is deleted", %{
      actor: actor,
      subject: subject,
      actor_group: actor_group
    } do
      assert_push "init", %{}
      # TODO: WAL
      # This is needed because the :reject_access received in the client channel re-fetches allowed resources for this client.
      # Remove this when that's cleaned up.
      {:ok, _actor} = Domain.Actors.update_actor(actor, %{memberships: []}, subject)

      assert :ok =
               on_delete(%{
                 "account_id" => actor.account_id,
                 "actor_id" => actor.id,
                 "group_id" => actor_group.id
               })

      assert_push "resource_deleted", _payload
      refute_push "resource_created_or_updated", _payload
    end
  end
end
