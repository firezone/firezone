defmodule Domain.Fixtures.Actors do
  use Domain.Fixture
  import Ecto.Changeset
  import Domain.Changeset
  alias Domain.{Actors, Membership}

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}",
      type: :static
    })
  end

  def create_managed_group(attrs \\ %{}) do
    attrs =
      attrs
      |> group_attrs()
      |> Map.put(:type, :managed)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, group} = Actors.create_managed_group(account, attrs)
    group
  end

  def create_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {provider, attrs} = Map.pop(attrs, :provider)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        if provider do
          Fixtures.Auth.random_provider_identifier(provider)
        end
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, group} =
      attrs
      |> Map.put(:provider_identifier, provider_identifier)
      |> Actors.create_group(subject)

    if provider do
      update!(group,
        provider_id: provider.id,
        provider_identifier: provider_identifier
      )
    else
      group
    end
  end

  def delete_group(group) do
    group = Repo.preload(group, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: group.account,
        actor: [type: :account_admin_user]
      )

    {:ok, group} = Actors.delete_group(group, subject)
    group
  end

  def actor_attrs(attrs \\ %{}) do
    first_name = Enum.random(~w[Wade Dave Seth Riley Gilbert Jorge Dan Brian Roberto Ramon Juan])
    last_name = Enum.random(~w[Robyn Traci Desiree Jon Bob Karl Joe Alberta Lynda Cara Brandi B])

    Enum.into(attrs, %{
      name: "#{first_name} #{last_name} #{unique_integer()}rd",
      type: :account_user
    })
  end

  def create_actor(attrs \\ %{}) do
    attrs = actor_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {_provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        {provider, _bypass} =
          assoc_attrs
          |> Enum.into(%{account: account})
          |> Fixtures.Auth.start_and_create_openid_connect_provider()

        provider
      end)

    {:ok, actor} = Actors.create_actor(account, attrs)

    actor
  end

  def create_membership(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {provider, attrs} = Map.pop(attrs, :provider)

    {group_id, attrs} =
      pop_assoc_fixture_id(attrs, :group, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, provider: provider})
        |> create_group()
      end)

    {actor_id, _attrs} =
      pop_assoc_fixture_id(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> create_actor()
      end)

    %Membership{}
    |> cast(
      %{
        group_id: group_id,
        actor_id: actor_id,
        last_synced_at: attrs[:last_synced_at]
      },
      ~w[actor_id group_id last_synced_at]a
    )
    |> validate_required_one_of(~w[actor_id group_id]a)
    |> Domain.Membership.changeset()
    |> put_change(:account_id, account.id)
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:group_id, :actor_id]
    )
  end

  def update(actor, updates) do
    update!(actor, updates)
  end

  def disable(actor) do
    update!(actor, %{disabled_at: DateTime.utc_now()})
  end

  def delete(actor) do
    actor = Repo.preload(actor, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: actor.account,
        actor: [type: :account_admin_user]
      )

    {:ok, deleted_actor} = Domain.Actors.delete_actor(actor, subject)
    deleted_actor
  end
end
