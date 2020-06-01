defmodule FgHttp.Users.PasswordReset do
  @moduledoc """
  Schema for PasswordReset
  """

  use Ecto.Schema
  import Ecto.Changeset

  @token_num_bytes 8
  # 1 day
  @token_validity_secs 86_400

  schema "users" do
    field :reset_sent_at, :utc_datetime
    field :reset_consumed_at, :utc_datetime
    field :reset_token, :string
    field :email, :string
  end

  @doc false
  def changeset do
    %__MODULE__{}
    |> cast(%{}, [:email, :reset_sent_at, :reset_token])
  end

  @doc false
  def create_changeset(%__MODULE__{} = password_reset, attrs) do
    password_reset
    |> cast(attrs, [:email, :reset_sent_at, :reset_token])
    |> validate_required([:email])
    |> generate_reset_token()
    |> validate_required([:reset_token])
    |> unique_constraint(:reset_token)
  end

  def token_validity_secs, do: @token_validity_secs

  defp generate_reset_token(%Ecto.Changeset{valid?: true} = changeset) do
    random_bytes = :crypto.strong_rand_bytes(@token_num_bytes)
    random_string = Base.url_encode64(random_bytes)
    put_change(changeset, :reset_token, random_string)
  end

  defp generate_reset_token(changeset), do: changeset
end
