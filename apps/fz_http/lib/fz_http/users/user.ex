defmodule FzHttp.Users.User do
  @moduledoc """
  Represents a User.
  """

  @min_password_length 12
  @max_password_length 64

  use Ecto.Schema
  import Ecto.Changeset
  import FzHttp.Users.PasswordHelpers
  import FzHttp.Validators.Common, only: [trim: 2]

  alias FzHttp.{Devices.Device, OIDC.Connection}

  # Fields for which to trim whitespace after cast, before validation
  @whitespace_trimmed_fields :email

  schema "users" do
    field :uuid, Ecto.UUID, autogenerate: true
    field :role, Ecto.Enum, values: [:unprivileged, :admin], default: :unprivileged
    field :email, :string
    field :last_signed_in_at, :utc_datetime_usec
    field :last_signed_in_method, :string
    field :password_hash, :string
    field :sign_in_token, :string
    field :sign_in_token_created_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec

    # VIRTUAL FIELDS
    field :device_count, :integer, virtual: true
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true

    has_many :devices, Device, on_delete: :delete_all
    has_many :oidc_connections, Connection, on_delete: :delete_all

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(user, attrs \\ %{}) do
    user
    |> cast(attrs, [
      :email,
      :password_hash,
      :password,
      :password_confirmation
    ])
    |> trim(@whitespace_trimmed_fields)
    |> validate_required([:email])
    |> validate_password_equality()
    |> validate_length(:password, min: @min_password_length, max: @max_password_length)
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  def require_current_password(user, attrs) do
    user
    |> cast(attrs, [:current_password])
    |> validate_required([:current_password])
    |> verify_current_password()
  end

  def update_password(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> then(fn
      %{changes: %{password: _}} = changeset ->
        validate_length(changeset, :password, min: @min_password_length, max: @max_password_length)

      changeset ->
        changeset
    end)
    |> validate_password_equality()
    |> put_password_hash()
    |> validate_required([:password_hash])
  end

  def require_password_change(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
  end

  def update_email(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> trim(:email)
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
  end

  def update_role(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
  end

  def update_sign_in_token(user, attrs) do
    cast(user, attrs, [:sign_in_token, :sign_in_token_created_at])
  end

  def update_last_signed_in(user, attrs) do
    cast(user, attrs, [:last_signed_in_method, :last_signed_in_at])
  end

  defp verify_current_password(
         %Ecto.Changeset{
           data: %{password_hash: password_hash},
           changes: %{current_password: current_password}
         } = changeset
       ) do
    if Argon2.verify_pass(current_password, password_hash) do
      delete_change(changeset, :current_password)
    else
      add_error(changeset, :current_password, "invalid password")
    end
  end

  defp verify_current_password(changeset), do: changeset
end
