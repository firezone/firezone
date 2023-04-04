defmodule Domain.MFAFixtures do
  alias Domain.Repo
  alias Domain.Auth.MFA
  alias Domain.UsersFixtures

  def totp_method_attrs(attrs \\ %{}) do
    secret = NimbleTOTP.secret()

    Enum.into(attrs, %{
      name: "Test Default #{counter()}",
      type: :totp,
      payload: %{"secret" => Base.encode64(secret)},
      code: NimbleTOTP.verification_code(secret)
    })
  end

  def create_totp_method(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {user, attrs} =
      Map.pop_lazy(attrs, :user, fn ->
        UsersFixtures.create_user_with_role(:admin)
      end)

    attrs = totp_method_attrs(attrs)
    {:ok, method} = MFA.create_method(attrs, user.id)
    method
  end

  @doc """
  By default, TOTP methods would not code reuse for 30 seconds after it was created,
  so we hack around it by moving `last_used_at` timestamp back in past.
  """
  def rotate_totp_method_key(%MFA.Method{} = method) do
    method
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now() |> DateTime.add(-3600, :second))
    |> Repo.update!()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
