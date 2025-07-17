defmodule Domain.Fixtures.Flows do
  use Domain.Fixture
  alias Domain.Flows

  def create_flow(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          actor: [type: :account_admin_user]
        })
        |> Fixtures.Auth.create_subject()
      end)

    {client, attrs} =
      pop_assoc_fixture(attrs, :client, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, subject: subject})
        |> Fixtures.Clients.create_client()
      end)

    {gateway_group, attrs} =
      pop_assoc_fixture(attrs, :gateway_group, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, subject: subject})
        |> Fixtures.Gateways.create_group()
      end)

    {gateway, attrs} =
      pop_assoc_fixture(attrs, :gateway, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          gateway_group: gateway_group,
          subject: subject
        })
        |> Fixtures.Gateways.create_gateway()
      end)

    {resource_id, attrs} =
      pop_assoc_fixture_id(attrs, :resource, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, subject: subject})
        |> Fixtures.Resources.create_resource()
      end)

    {membership, attrs} =
      pop_assoc_fixture(attrs, :actor_group_membership, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          subject: subject,
          actor_id: client.actor_id
        })
        |> Fixtures.Actors.create_membership()
      end)

    {policy_id, attrs} =
      pop_assoc_fixture_id(attrs, :policy, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          actor_group_id: membership.group_id,
          resource_id: resource_id,
          subject: subject
        })
        |> Fixtures.Policies.create_policy()
      end)

    {token_id, _attrs} = Map.pop(attrs, :token_id, subject.token_id)

    Flows.Flow.Changeset.create(%{
      token_id: token_id,
      policy_id: policy_id,
      client_id: client.id,
      gateway_id: gateway.id,
      resource_id: resource_id,
      actor_group_membership_id: membership.id,
      account_id: account.id,
      client_remote_ip: client.last_seen_remote_ip,
      client_user_agent: client.last_seen_user_agent,
      gateway_remote_ip: gateway.last_seen_remote_ip
    })
    |> Repo.insert!()
  end
end
