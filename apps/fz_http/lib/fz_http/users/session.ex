defmodule FzHttp.Users.Session do
  @moduledoc """
  Represents a Session
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias FzHttp.{Users, Users.User}

  schema "users" do
    field :role, Ecto.Enum, values: [:unprivileged, :admin], default: :unprivileged
    field :email, :string
    field :password, :string, virtual: true
    field :last_signed_in_at, :utc_datetime_usec
  end

  def create_changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [:email, :password, :last_signed_in_at])
    |> authenticate_user()
    |> set_last_signed_in_at()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:email, :password, :last_signed_in_at])
  end

  defp set_last_signed_in_at(%Ecto.Changeset{valid?: true} = changeset) do
    last_signed_in_at = DateTime.utc_now()
    change(changeset, last_signed_in_at: last_signed_in_at)
  end

  defp set_last_signed_in_at(changeset), do: changeset

  defp authenticate_user(%Ecto.Changeset{valid?: true} = changeset) do
    email = changeset.data.email
    password = changeset.changes[:password]
    user = Users.get_user!(email: email)

    case User.authenticate_user(user, password) do
      {:ok, _} ->
        changeset

      {:error, error_msg} ->
        add_error(changeset, :password, "invalid: #{error_msg}")
    end
  end
end
