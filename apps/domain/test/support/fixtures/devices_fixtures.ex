defmodule Domain.DevicesFixtures do
  alias Domain.Devices
  alias Domain.UsersFixtures
  alias Domain.SubjectFixtures

  def device_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      public_key: public_key(),
      name: "factory #{counter()}",
      description: "factory description"
    })
  end

  def create_device(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {user, attrs} =
      Map.pop_lazy(attrs, :user, fn -> UsersFixtures.create_user_with_role(:unprivileged) end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        UsersFixtures.create_user_with_role(:admin)
        |> SubjectFixtures.create_subject()
      end)

    attrs = device_attrs(attrs)

    {:ok, device} = Devices.create_device_for_user(user, attrs, subject)
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
