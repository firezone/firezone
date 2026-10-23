defmodule Portal.Google.AuthProvider do
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

  schema "google_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, :binary_id, primary_key: true

    belongs_to :account, Portal.Account

    belongs_to :auth_provider, Portal.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :issuer, :string
    field :workspace_domains, {:array, :string}
    field :is_legacy_unrestricted, :boolean, default: false

    field :context, Ecto.Enum,
      values: ~w[clients_and_portal clients_only portal_only]a,
      default: :clients_and_portal

    field :client_session_lifetime_secs, :integer
    field :portal_session_lifetime_secs, :integer

    field :is_verified, :boolean, virtual: true, default: false

    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "Google"

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name, :context, :issuer, :is_verified])
    |> validate_acceptance(:is_verified)
    |> validate_length(:workspace_domains, min: 1)
    |> check_constraint(:workspace_domains, name: :google_workspace_domains_must_not_be_empty)
    |> check_constraint(:workspace_domains, name: :google_legacy_unrestricted_requires_no_domains)
    |> exclusion_constraint(:workspace_domains,
      name: :google_auth_providers_workspace_domains_excl,
      message: "A domain is already verified on another Google authentication provider in this account."
    )
    |> validate_length(:issuer, min: 1, max: 2_000)
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
    |> unique_constraint(:workspace_domains,
      name: :google_auth_providers_account_id_unrestricted_index,
      message: "Only one Google authentication provider without Workspace domains is allowed per account."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
  end

  def default_portal_session_lifetime_secs, do: @default_portal_session_lifetime_secs
  def default_client_session_lifetime_secs, do: @default_client_session_lifetime_secs
end
