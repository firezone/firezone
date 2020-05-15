defmodule FgHttp.Sessions.Session do
  @moduledoc """
  Represents a Session
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Users.User}

  schema "sessions" do
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(session, attrs \\ %{}) do
    session
    |> cast(attrs, [])
    |> validate_required([])
  end
end
