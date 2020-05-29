defmodule FgHttp.Users.PasswordReset do
  @moduledoc """
  Schema for PasswordReset
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FgHttp.{Users, Users.User}

  @token_num_bytes 8
  # 1 day
  @token_validity_secs 86_400

  schema "password_resets" do
    field :reset_sent_at, :utc_datetime
    field :reset_token, :string
    field :consumed_at, :string
    field :user_email, :string, virtual: true
    belongs_to :user, User

    timestamps()
  end

  @doc false
  def changeset(password_reset, attrs) do
    password_reset
    |> cast(attrs, [:user_id, :user_email, :reset_sent_at, :reset_token])
  end

  @doc false
  def create_changeset(password_reset, attrs) do
    password_reset
    |> cast(attrs, [:user_id, :user_email, :reset_sent_at, :reset_token])
    |> load_user_from_email()
    |> generate_reset_token()
    |> validate_required([:reset_token, :user_id])
    |> unique_constraint(:reset_token)
  end

  @doc false
  def update_changeset(password_reset, attrs) do
    password_reset
    |> cast(attrs, [:user_id, :user_email, :reset_sent_at, :reset_token])
    |> validate_required([:reset_token])
  end

  def token_validity_secs, do: @token_validity_secs

  defp load_user_from_email(
         %Ecto.Changeset{
           valid?: true,
           changes: %{user_email: user_email}
         } = changeset
       ) do
    user = Users.get_user!(email: user_email)
    put_change(changeset, :user_id, user.id)
  end

  defp load_user_from_email(changeset), do: changeset

  defp generate_reset_token(%Ecto.Changeset{valid?: true} = changeset) do
    random_bytes = :crypto.strong_rand_bytes(@token_num_bytes)
    random_string = Base.url_encode64(random_bytes)
    put_change(changeset, :reset_token, random_string)
  end

  defp generate_reset_token(changeset), do: changeset
end
