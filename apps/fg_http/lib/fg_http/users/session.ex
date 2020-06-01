defmodule FgHttp.Users.Session do
  @moduledoc """
  Represents a Session
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Users, Users.User}

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true
    field :last_signed_in_at, :utc_datetime
  end

  def create_changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> authenticate_user()
    |> set_last_signed_in_at()
  end

  defp set_last_signed_in_at(%Ecto.Changeset{valid?: true} = changeset) do
    last_signed_in_at = DateTime.truncate(DateTime.utc_now(), :second)
    change(changeset, last_signed_in_at: last_signed_in_at)
  end

  defp set_last_signed_in_at(changeset), do: changeset

  defp authenticate_user(
         %Ecto.Changeset{
           valid?: true,
           changes: %{email: email, password: password}
         } = changeset
       ) do
    user = Users.get_user!(email: email)

    case User.authenticate_user(user, password) do
      {:ok, _} ->
        # Remove the user's password so it doesn't accidentally end up somewhere
        changeset
        |> delete_change(:password)
        |> change(%{id: user.id})

      {:error, error_msg} ->
        raise("There was an issue with your password: #{error_msg}")
    end
  end

  defp authenticate_user(changeset), do: delete_change(changeset, :password)
end
