defmodule Domain.ActorsFixtures do
  alias Domain.Repo
  alias Domain.Actors
  alias Domain.{AccountsFixtures, AuthFixtures}

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{counter()}"
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        actor = create_actor(type: :account_admin_user, account: account)
        identity = AuthFixtures.create_identity(account: account, actor: actor)
        AuthFixtures.create_subject(identity)
      end)

    attrs = group_attrs(attrs)

    {:ok, group} = Actors.create_group(attrs, subject)
    group
  end

  # def create_provider_group(attrs \\ %{}) do
  #   attrs = Enum.into(attrs, %{})

  #   {account, attrs} =
  #     Map.pop_lazy(attrs, :account, fn ->
  #       AccountsFixtures.create_account()
  #     end)

  #   {provider_identifier, attrs} =
  #     Map.pop_lazy(attrs, :provider_identifier, fn ->
  #       Ecto.UUID.generate()
  #     end)

  #   {provider, attrs} =
  #     Map.pop_lazy(attrs, :account, fn ->
  #       AccountsFixtures.create_account()
  #     end)

  #   attrs = group_attrs(attrs)

  #   {:ok, group} = Actors.upsert_provider_group(provider, provider_identifier, attrs)
  #   group
  # end

  def delete_group(group) do
    group = Repo.preload(group, :account)
    actor = create_actor(type: :account_admin_user, account: group.account)
    identity = AuthFixtures.create_identity(account: group.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
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
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {provider, attrs} =
      Map.pop_lazy(attrs, :provider, fn ->
        {provider, _bypass} =
          AuthFixtures.start_openid_providers(["google"])
          |> AuthFixtures.create_openid_connect_provider(account: account)

        provider
      end)

    attrs = actor_attrs(attrs)

    Actors.Actor.Changeset.create_changeset(provider, attrs)
    |> Repo.insert!()
  end

  def update(actor, updates) do
    actor
    |> Ecto.Changeset.change(Map.new(updates))
    |> Repo.update!()
  end

  def disable(actor) do
    update(actor, %{disabled_at: DateTime.utc_now()})
  end

  def delete(actor) do
    update(actor, %{deleted_at: DateTime.utc_now()})
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
