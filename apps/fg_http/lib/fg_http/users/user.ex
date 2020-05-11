defmodule FgHttp.Users.User do
  @moduledoc """
  Represents a User I guess
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :last_signed_in_at, :utc_datetime
    field :password_digest, :string

    timestamps()
  end

  @doc false
  def changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:email, :confirmed_at, :password_digest, :last_signed_in_at])
    |> validate_required([:email, :last_signed_in_at])
    |> unique_constraint(:email)
  end
end
