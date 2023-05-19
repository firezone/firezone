defmodule Domain.AuthFixtures do
  alias Domain.Repo
  alias Domain.Auth
  alias Domain.AccountsFixtures
  alias Domain.ActorsFixtures

  def remote_ip, do: {100, 64, 100, 58}
  def user_agent, do: "iOS/12.5 (iPhone) connlib/0.7.412"

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :email, name: name}) do
    "user-#{counter()}@#{String.downcase(name)}.com"
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :openid_connect}) do
    Ecto.UUID.generate()
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :userpass, name: name}) do
    "user-#{counter()}@#{String.downcase(name)}.com"
  end

  def provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "provider-#{counter()}",
      adapter: :email,
      adapter_config: %{}
    })
  end

  def create_email_provider(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = provider_attrs(attrs)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_openid_connect_provider({bypass, [provider_attrs]}, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs =
      %{adapter_config: provider_attrs}
      |> Map.merge(attrs)
      |> provider_attrs()

    {:ok, provider} = Auth.create_provider(account, attrs)
    {provider, bypass}
  end

  def create_userpass_provider(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, _attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = provider_attrs(adapter: :userpass)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def create_identity(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {provider, attrs} =
      Map.pop_lazy(attrs, :provider, fn ->
        create_email_provider(account: account)
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, _attrs} =
      Map.pop_lazy(attrs, :actor, fn ->
        ActorsFixtures.create_actor(
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        )
      end)

    {provider_virtual_state, attrs} =
      Map.pop_lazy(attrs, :provider_virtual_state, fn ->
        %{}
      end)

    {:ok, identity} =
      Auth.create_identity(actor, provider, provider_identifier, provider_virtual_state)

    if state = Map.get(attrs, :provider_state) do
      identity
      |> Ecto.Changeset.change(provider_state: state)
      |> Repo.update!()
    else
      identity
    end
  end

  def create_subject do
    account = AccountsFixtures.create_account()
    actor = ActorsFixtures.create_actor(role: :admin, account: account)
    identity = create_identity(actor: actor, account: account)
    create_subject(identity)
  end

  def create_subject(%Auth.Identity{} = identity) do
    identity = Repo.preload(identity, [:account, :actor])

    %Auth.Subject{
      identity: identity,
      actor: identity.actor,
      permissions: Auth.Roles.build(identity.actor.role).permissions,
      account: identity.account,
      expires_at: DateTime.utc_now() |> DateTime.add(60, :second),
      context: %Auth.Context{remote_ip: remote_ip(), user_agent: user_agent()}
    }
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def set_permissions(%Auth.Subject{} = subject, permissions) do
    %{subject | permissions: MapSet.new(permissions)}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
