defmodule Domain.Fixtures.Actors do
  use Domain.Fixture
  alias Domain.Actors

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}",
      type: :static
    })
  end

  def create_managed_group(attrs \\ %{}) do
    attrs = group_attrs(attrs) |> Map.put(:type, :managed)

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
      update!(group, provider_id: provider.id, provider_identifier: provider_identifier)
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

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        {provider, _bypass} =
          assoc_attrs
          |> Enum.into(%{account: account})
          |> Fixtures.Auth.start_and_create_openid_connect_provider()

        provider
      end)

    Actors.Actor.Changeset.create(provider.account_id, attrs)
    |> Repo.insert!()
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

    Actors.Membership.Changeset.upsert(account.id, %Actors.Membership{}, %{
      group_id: group_id,
      actor_id: actor_id
    })
    |> Repo.insert!()
  end

  def update(actor, updates) do
    update!(actor, updates)
  end

  def disable(actor) do
    update!(actor, %{disabled_at: DateTime.utc_now()})
  end

  def delete(actor) do
    update!(actor, %{deleted_at: DateTime.utc_now()})
  end
end
