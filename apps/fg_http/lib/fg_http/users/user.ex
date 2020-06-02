defmodule FgHttp.Users.User do
  @moduledoc """
  Represents a User I guess
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FgHttp.Users.PasswordHelpers

  alias FgHttp.Devices.Device

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime_usec
    field :last_signed_in_at, :utc_datetime_usec
    field :password_hash, :string

    # VIRTUAL FIELDS
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true

    has_many :devices, Device, on_delete: :delete_all

    timestamps(type: :utc_datetime_usec)
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

  # Password updated with user logged in
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
    |> validate_password_equality()
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Password updated from token
  def update_changeset(
        user,
        %{
          user: %{
            password: _password,
            password_confirmation: _password_confirmation
          }
        } = attrs
      ) do
    user
    |> cast(attrs, [:email, :password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_password_equality()
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Only email being updated
  def update_changeset(user, %{user: %{email: _email}} = attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
  end

  def changeset(%__MODULE__{} = _user, _attrs \\ %{}) do
    change(%__MODULE__{})
  end

  def authenticate_user(user, password_candidate) do
    Argon2.check_pass(user, password_candidate)
  end

  defp verify_current_password(user, current_password) do
    {:ok, user} = authenticate_user(user, current_password)
    user
  end
end
