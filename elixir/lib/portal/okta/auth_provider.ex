defmodule Portal.Okta.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @portal_session_lifetime_min 300
  @portal_session_lifetime_max 86_400
  @default_portal_session_lifetime_secs 28_800

  @client_session_lifetime_min 3_600
  @client_session_lifetime_max 7_776_000
  @default_client_session_lifetime_secs 604_800

  schema "okta_auth_providers" do
    # Allows setting the ID manually in changesets
    field :id, :binary_id, primary_key: true

    belongs_to :account, Portal.Account

    belongs_to :auth_provider, Portal.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :issuer, :string

    field :context, Ecto.Enum,
      values: ~w[clients_and_portal clients_only portal_only]a,
      default: :clients_and_portal

    field :client_session_lifetime_secs, :integer
    field :portal_session_lifetime_secs, :integer

    field :is_verified, :boolean, virtual: true, default: false

    field :is_disabled, :boolean, read_after_writes: true, default: false
    field :is_default, :boolean, read_after_writes: true, default: false

    field :name, :string, default: "Okta"
    field :client_id, :string
    field :client_secret, :string, redact: true
    field :okta_domain, :string

    # Built from the okta_domain
    field :discovery_document_uri, :string, virtual: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :name,
      :context,
      :okta_domain,
      :client_id,
      :client_secret,
      :is_verified
    ])
    |> validate_acceptance(:is_verified)
    |> put_discovery_document_uri()
    |> validate_required(:discovery_document_uri)
    |> validate_uri(:discovery_document_uri)
    |> validate_length(:okta_domain, min: 1, max: 255)
    |> validate_fqdn(:okta_domain)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> validate_issuer_contains_okta_domain()
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 255)
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
    |> unique_constraint(:client_id,
      name: :okta_auth_providers_account_id_client_id_index,
      message: "An Okta authentication provider with this client id already exists."
    )
    |> unique_constraint(:name,
      name: :okta_auth_providers_account_id_name_index,
      message: "An Okta authentication provider with this name already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
  end

  def default_portal_session_lifetime_secs, do: @default_portal_session_lifetime_secs
  def default_client_session_lifetime_secs, do: @default_client_session_lifetime_secs

  defp validate_issuer_contains_okta_domain(changeset) do
    okta_domain = get_field(changeset, :okta_domain)
    issuer = get_field(changeset, :issuer)

    if "https://#{okta_domain}" == issuer do
      changeset
    else
      add_error(changeset, :issuer, "must equal https://<okta_domain>")
    end
  end

  defp put_discovery_document_uri(changeset) do
    case get_field(changeset, :okta_domain) do
      nil ->
        changeset

      okta_domain ->
        uri = "https://#{okta_domain}/.well-known/openid-configuration"
        put_change(changeset, :discovery_document_uri, uri)
    end
  end
end
