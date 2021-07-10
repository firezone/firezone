defmodule FzHttp.Users.PasswordReset do
  @moduledoc """
  Schema for PasswordReset
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FzHttp.Users.PasswordHelpers

  alias FzCommon.FzCrypto

  @token_num_bytes 8
  # 1 day
  @token_validity_secs 86_400

  schema "users" do
    field :reset_sent_at, :utc_datetime_usec
    field :password_hash, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :reset_token, :string
    field :email, :string
  end

  def changeset do
    %__MODULE__{}
    |> cast(%{}, [:password, :password_confirmation, :reset_token, :reset_sent_at])
  end

  def changeset(%__MODULE__{} = password_reset, attrs \\ %{}) do
    password_reset
    |> cast(attrs, [:password, :password_confirmation, :reset_token, :reset_sent_at])
  end

  def create_changeset(%__MODULE__{} = password_reset, attrs) do
    password_reset
    |> cast(attrs, [:reset_sent_at, :reset_token])
    |> generate_reset_token()
    |> validate_required([:reset_token])
    |> unique_constraint(:reset_token)
    |> set_reset_sent_at()
    |> validate_required([:reset_sent_at])
  end

  def update_changeset(%__MODULE__{} = password_reset, attrs) do
    password_reset
    |> cast(attrs, [
      :password_hash,
      :password,
      :password_confirmation,
      :reset_token,
      :reset_sent_at
    ])
    |> validate_required([:password, :password_confirmation])
    |> validate_password_equality()
    |> put_password_hash()
    |> validate_required([:password_hash])
    |> clear_token_fields()
  end

  def token_validity_secs, do: @token_validity_secs

  defp generate_reset_token(%Ecto.Changeset{valid?: true} = changeset) do
    put_change(changeset, :reset_token, FzCrypto.rand_token(@token_num_bytes))
  end

  defp clear_token_fields(
         %Ecto.Changeset{
           valid?: true
         } = changeset
       ) do
    changeset
    |> put_change(:reset_token, nil)
    |> put_change(:reset_sent_at, nil)
  end

  defp clear_token_fields(changeset), do: changeset

  defp set_reset_sent_at(%Ecto.Changeset{valid?: true} = changeset) do
    changeset
    |> put_change(:reset_sent_at, DateTime.utc_now())
  end
end
