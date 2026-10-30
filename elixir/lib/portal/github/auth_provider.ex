defmodule Portal.GitHub.AuthProvider do
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

  # GitHub does not implement OpenID Connect for user sign-in, but it publishes
  # this issuer in its OAuth server metadata (RFC 8414) and returns it as `iss`
  # on authorization callbacks (RFC 9207). Identities from GitHub are keyed on it
  # and the GitHub user ID.
  @issuer "https://github.com/login/oauth"

  schema "github_auth_providers" do
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

    field :name, :string, default: "GitHub"

    # How a GitHub identity is first linked to an existing actor by email.
    # - proof: email a one-time code to the actor before linking
    # - none: link on an email GitHub has verified, without a code
    # GitHub never re-checks an address once verified, so proof is the default.
    field :email_verification_method, Ecto.Enum,
      values: ~w[none proof]a,
      default: :proof

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name, :context, :issuer, :is_verified, :email_verification_method])
    |> validate_acceptance(:is_verified)
    |> validate_inclusion(:issuer, [@issuer])
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
    |> unique_constraint(:issuer,
      name: :github_auth_providers_account_id_index,
      message: "A GitHub authentication provider for this account already exists."
    )
    |> check_constraint(:context, name: :context_must_be_valid)
    |> check_constraint(:email_verification_method,
      name: :email_verification_method_must_be_valid
    )
  end

  @spec issuer() :: String.t()
  def issuer, do: @issuer

  def default_portal_session_lifetime_secs, do: @default_portal_session_lifetime_secs
  def default_client_session_lifetime_secs, do: @default_client_session_lifetime_secs
end
