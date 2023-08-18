defmodule Domain.Fixtures.Actors do
  use Domain.Fixture
  alias Domain.Actors

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}"
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {provider, attrs} =
      Map.pop(attrs, :provider)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        if provider do
          Fixtures.Auth.random_provider_identifier(provider)
        end
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        admin_subject_for_account(account)
      end)

    {:ok, group} = Actors.create_group(attrs, subject)

    if provider do
      update!(group, provider_id: provider.id, provider_identifier: provider_identifier)
    else
      group
    end
  end

  def delete_group(group) do
    group = Repo.preload(group, :account)
    subject = admin_subject_for_account(group.account)
    {:ok, group} = Actors.delete_group(group, subject)
    group
  end

  def actor_attrs(attrs \\ %{}) do
    first_name = Enum.random(~w[Wade Dave Seth Riley Gilbert Jorge Dan Brian Roberto Ramon])
    last_name = Enum.random(~w[Robyn Traci Desiree Jon Bob Karl Joe Alberta Lynda Cara Brandi])

    Enum.into(attrs, %{
      name: "#{first_name} #{last_name}",
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

    # FIXME!!!
    Actors.Actor.Changeset.create_changeset(provider.account_id, attrs)
    |> Repo.insert!()
  end

  def disable(actor) do
    update!(actor, %{disabled_at: DateTime.utc_now()})
  end

  def delete(actor) do
    update!(actor, %{deleted_at: DateTime.utc_now()})
  end
end
