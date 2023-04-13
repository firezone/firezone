defmodule Domain.ClientsFixtures do
  alias Domain.Clients
  alias Domain.{UsersFixtures, SubjectFixtures}

  def client_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name: "client-#{counter()}",
      preshared_key: Domain.Crypto.psk(),
      public_key: public_key()
    })
  end

  def create_client(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {user, attrs} =
      Map.pop_lazy(attrs, :user, fn ->
        UsersFixtures.create_user_with_role(:unprivileged)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        SubjectFixtures.create_subject(user)
      end)

    attrs = client_attrs(attrs)

    {:ok, client} = Clients.upsert_client(attrs, subject)
    client
  end

  def delete_client(client) do
    admin = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(admin)
    {:ok, client} = Clients.delete_client(client, subject)
    client
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
