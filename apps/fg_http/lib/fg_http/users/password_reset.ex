defmodule FgHttp.Users.PasswordReset do
  @moduledoc """
  Schema for PasswordReset
  """

  use Ecto.Schema
  import Ecto.Changeset
  import FgHttp.Users.PasswordHelpers

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
    |> cast(%{}, [:password, :password_confirmation, :reset_token])
  end

  def changeset(%__MODULE__{} = password_reset, attrs \\ %{}) do
    password_reset
    |> cast(attrs, [:password, :password_confirmation, :reset_token])
  end

  def create_changeset(%__MODULE__{} = password_reset, attrs) do
    password_reset
    |> cast(attrs, [:email, :reset_sent_at, :reset_token])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
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
    # XXX: Use FgCrypto here
    random_bytes = :crypto.strong_rand_bytes(@token_num_bytes)
    random_string = Base.url_encode64(random_bytes)
    put_change(changeset, :reset_token, random_string)
  end

  defp generate_reset_token(changeset), do: changeset

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

  defp set_reset_sent_at(changeset), do: changeset
end
