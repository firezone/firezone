defmodule Portal.EmailOTP.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @portal_session_lifetime_min 300
  @portal_session_lifetime_max 86_400
  @default_portal_session_lifetime_secs 28_800

  @client_session_lifetime_min 3_600
  @client_session_lifetime_max 7_776_000
  @default_client_session_lifetime_secs 604_800

  schema "email_otp_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, :binary_id, primary_key: true

    belongs_to :account, Portal.Account

    belongs_to :auth_provider, Portal.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string

    field :issuer, :string, read_after_writes: true

    field :context, Ecto.Enum,
      values: ~w[clients_and_portal clients_only portal_only]a,
      default: :clients_and_portal

    field :client_session_lifetime_secs, :integer
    field :portal_session_lifetime_secs, :integer

    field :is_disabled, :boolean, read_after_writes: true, default: false

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name, :context])
    |> validate_number(:portal_session_lifetime_secs,
      greater_than_or_equal_to: @portal_session_lifetime_min,
      less_than_or_equal_to: @portal_session_lifetime_max
    )
    |> validate_number(:client_session_lifetime_secs,
      greater_than_or_equal_to: @client_session_lifetime_min,
      less_than_or_equal_to: @client_session_lifetime_max
    )
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:account_id,
      name: :email_otp_auth_providers_account_id_index,
      message: "An Email OTP authentication provider for this account already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> check_constraint(:issuer, name: :issuer_must_be_firezone)
  end

  def default_portal_session_lifetime_secs, do: @default_portal_session_lifetime_secs
  def default_client_session_lifetime_secs, do: @default_client_session_lifetime_secs
end
