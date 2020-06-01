defmodule FgHttp.Users.User do
  @moduledoc """
  Represents a User I guess
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.Devices.Device

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :last_signed_in_at, :utc_datetime
    field :password_hash, :string

    # VIRTUAL FIELDS
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true

    has_many :devices, Device, on_delete: :delete_all

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

  defp validate_password_equality(%Ecto.Changeset{valid?: true} = changeset) do
    password = changeset.changes[:password]
    password_confirmation = changeset.changes[:password_confirmation]

    if password != password_confirmation do
      add_error(changeset, :password, "does not match password confirmation.")
    else
      changeset
    end
  end

  defp validate_password_equality(changeset), do: changeset

  defp put_password_hash(
         %Ecto.Changeset{
           valid?: true,
           changes: %{password: password}
         } = changeset
       ) do
    changeset
    |> change(password_hash: Argon2.hash_pwd_salt(password))
    |> delete_change(:password)
    |> delete_change(:password_confirmation)
  end

  defp put_password_hash(changeset) do
    changeset
    |> delete_change(:password)
    |> delete_change(:password_confirmation)
  end
end
