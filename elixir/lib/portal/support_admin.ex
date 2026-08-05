defmodule Portal.SupportAdmin do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @max_otp_attempts 3
  @otp_lifetime_secs 900
  @registration_token_lifetime_secs 3_600

  schema "support_admins" do
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :email, :string

    field :passkey_credential_id, :binary
    field :passkey_public_key, :binary, redact: true
    field :passkey_sign_count, :integer, default: 0
    field :passkey_registered_at, :utc_datetime_usec

    field :registration_token_hash, :string, redact: true
    field :registration_token_expires_at, :utc_datetime_usec

    field :otp_code_hash, :string, redact: true
    field :otp_code, :string, virtual: true, redact: true
    field :otp_expires_at, :utc_datetime_usec
    field :otp_attempts, :integer, default: 0

    field :challenge_hash, :string, redact: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(:email)
    |> update_change(:email, &String.downcase/1)
    |> validate_required(~w[email]a)
    |> validate_email(:email)
    |> validate_format(:email, ~r/@firezone\.dev$/i, message: "must be a firezone.dev email")
    |> validate_number(:otp_attempts, greater_than_or_equal_to: 0)
    |> unique_constraint(:email, name: :support_admins_email_index)
    |> unique_constraint(:passkey_credential_id,
      name: :support_admins_passkey_credential_id_index
    )
    |> check_constraint(:email, name: :email_must_be_firezone)
  end

  def max_otp_attempts, do: @max_otp_attempts
  def otp_lifetime_secs, do: @otp_lifetime_secs
  def registration_token_lifetime_secs, do: @registration_token_lifetime_secs
end
