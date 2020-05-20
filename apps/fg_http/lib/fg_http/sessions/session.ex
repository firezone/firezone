defmodule FgHttp.Sessions.Session do
  @moduledoc """
  Represents a Session
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Users, Users.User}

  schema "sessions" do
    field :deleted_at, :utc_datetime
    belongs_to :user, User

    # VIRTUAL FIELDS
    field :user_email, :string, virtual: true
    field :user_password, :string, virtual: true

    timestamps()
  end

  @doc false
  def changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [:deleted_at])
    |> validate_required([])
  end

  def create_changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [:user_email, :user_password])
    |> validate_required([:user_email, :user_password])
    |> authenticate_user()
  end

  defp authenticate_user(
         %Ecto.Changeset{
           valid?: true,
           changes: %{user_email: email, user_password: password}
         } = changeset
       ) do
    user = Users.get_user!(email: email)

    case User.authenticate_user(user, password) do
      {:ok, _} ->
        change(changeset, user_id: user.id)

      {:error, error_msg} ->
        raise("There was an issue with your password: #{error_msg}")
    end
  end

  defp authenticate_user(changeset), do: changeset
end
