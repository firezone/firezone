defmodule FgHttp.Users.User do
  @moduledoc """
  Represents a User I guess
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FgHttp.Users.PasswordHelpers

  alias FgHttp.{Devices.Device, Util.FgMap}

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

  def create_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [:email, :password_hash, :password, :password_confirmation])
    |> validate_required([:email, :password, :password_confirmation])
    |> validate_password_equality()
    |> unique_constraint(:email)
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Password updated with user logged in
  def update_changeset(
        user,
        %{
          "password" => nil,
          "password_confirmation" => nil,
          "current_password" => nil
        } = attrs
      ) do
    update_changeset(user, FgMap.compact(attrs))
  end

  def update_changeset(
        user,
        %{
          "password" => _password,
          "password_confirmation" => _password_confirmation,
          "current_password" => _current_password
        } = attrs
      ) do
    user
    |> cast(attrs, [:email, :password, :password_confirmation, :current_password])
    |> validate_required([:password, :password_confirmation, :current_password])
    |> verify_current_password(user)
    |> validate_password_equality()
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  # Password updated from token
  def update_changeset(
        user,
        %{
          "password" => _password,
          "password_confirmation" => _password_confirmation
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
  def update_changeset(user, %{"email" => _email} = attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :confirmed_at, :last_signed_in_at])
  end

  def authenticate_user(user, password_candidate) do
    Argon2.check_pass(user, password_candidate)
  end

  defp verify_current_password(changeset, user) do
    case authenticate_user(user, changeset.changes.current_password) do
      {:ok, _user} ->
        changeset
        |> delete_change(:current_password)

      {:error, error_msg} ->
        changeset
        |> add_error(:current_password, "is invalid: #{error_msg}")
    end
  end
end
