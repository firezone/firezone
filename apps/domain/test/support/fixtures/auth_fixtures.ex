defmodule Domain.AuthFixtures do
  alias Domain.Auth
  alias Domain.AccountsFixtures
  alias Domain.ActorsFixtures

  def build_subject(actor \\ nil, account \\ AccountsFixtures.create_account()) do
    %Auth.Subject{
      actor: actor,
      account: account,
      permissions: MapSet.new()
    }
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :email, name: name}) do
    "user-#{counter()}@#{String.downcase(name)}.com"
  end

  def provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "provider-#{counter()}}",
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

  def create_subject(actor \\ ActorsFixtures.create_actor(role: :admin)) do
    Domain.Auth.fetch_subject!(actor, {100, 64, 100, 58}, "iOS/12.5 (iPhone) connlib/0.7.412")
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
