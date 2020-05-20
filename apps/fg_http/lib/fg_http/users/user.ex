defmodule FgHttp.Users.User do
  @moduledoc """
  Represents a User I guess
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Devices.Device, Sessions.Session}

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :reset_sent_at, :utc_datetime
    field :last_signed_in_at, :utc_datetime
    field :password_hash, :string

    # VIRTUAL FIELDS
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true

    has_many :devices, Device, on_delete: :delete_all
    has_many :sessions, Session, on_delete: :delete_all

    timestamps()
  end

  @doc false
  def create_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:email, :password_hash, :password, :password_confirmation])
    |> validate_required([:email, :password, :password_confirmation])
    |> unique_constraint(:email)
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Only password being updated
  def update_changeset(
        user,
        %{
          user: %{
            password: _password,
            password_confirmation: _password_confirmation,
            current_password: _current_password
          }
        } = attrs
      ) do
    user
    |> cast(attrs, [:email, :password, :password_confirmation, :current_password])
    |> verify_current_password(attrs[:current_password])
    |> validate_required([:password, :password_confirmation, :current_password])
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Only email being updated
  def update_changeset(user, %{user: %{email: _email}} = attrs) do
    user
    |> cast(attrs, [:email])
  end

  # Edit user
  def changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:email])
  end

  def authenticate_user(user, password_candidate) do
    Argon2.check_pass(user, password_candidate)
  end

  defp verify_current_password(user, current_password) do
    {:ok, user} = authenticate_user(user, current_password)
    user
  end

  defp put_password_hash(
         %Ecto.Changeset{
           valid?: true,
           changes: %{password: password}
         } = changeset
       ) do
    change(changeset, password_hash: Argon2.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset
end
