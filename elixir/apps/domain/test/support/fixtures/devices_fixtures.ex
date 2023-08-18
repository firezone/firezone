defmodule Domain.DevicesFixtures do
  alias Domain.Repo
  alias Domain.Devices
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  def device_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name: "device-#{counter()}",
      public_key: public_key()
    })
  end

  def create_device(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        if relation = attrs[:actor] || attrs[:identity] do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          AccountsFixtures.create_account()
        end
      end)

    {actor, attrs} =
      Map.pop_lazy(attrs, :actor, fn ->
        ActorsFixtures.create_actor(type: :account_admin_user, account: account)
      end)

    {identity, attrs} =
      Map.pop_lazy(attrs, :identity, fn ->
        AuthFixtures.create_identity(account: account, actor: actor)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        AuthFixtures.create_subject(identity)
      end)

    attrs = device_attrs(attrs)

    {:ok, device} = Devices.upsert_device(attrs, subject)
    %{device | online?: false}
  end

  def delete_device(device) do
    device = Repo.preload(device, :account)
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: device.account)
    identity = AuthFixtures.create_identity(account: device.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, device} = Devices.delete_device(device, subject)
    device
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
