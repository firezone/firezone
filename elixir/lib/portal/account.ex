defmodule Portal.Account do
  use Ecto.Schema
  import Ecto.Changeset
  alias Portal.Config

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field :name, :string
    field :slug, :string

    field :legal_name, :string

    # Updated by the billing subscription metadata fields
    embeds_one :features, Portal.Accounts.Features, on_replace: :delete
    embeds_one :limits, Portal.Accounts.Limits, on_replace: :delete
    embeds_one :config, Portal.Accounts.Config, on_replace: :update

    embeds_one :metadata, Portal.Account.Metadata, on_replace: :update

    # We mention all schemas here to leverage Ecto compile-time reference checks,
    # because later we will have to shard data by account_id.
    has_many :actors, Portal.Actor
    has_many :memberships, Portal.Membership
    has_many :groups, Portal.Group

    has_many :auth_providers, Portal.AuthProvider
    has_many :external_identities, Portal.ExternalIdentity

    has_many :ipv4_addresses, Portal.IPv4Address
    has_many :ipv6_addresses, Portal.IPv6Address

    has_many :policies, Portal.Policy

    has_many :policy_authorizations, Portal.PolicyAuthorization

    has_many :resources, Portal.Resource

    has_many :clients, Portal.Client

    has_many :gateways, Portal.Gateway
    has_many :sites, Portal.Site

    has_many :client_tokens, Portal.ClientToken
    has_many :gateway_tokens, Portal.GatewayToken
    has_many :one_time_passcodes, Portal.OneTimePasscode

    has_many :google_directories, Portal.Google.Directory
    has_many :google_auth_providers, Portal.Google.AuthProvider
    has_many :okta_directories, Portal.Okta.Directory
    has_many :okta_auth_providers, Portal.Okta.AuthProvider
    has_many :entra_directories, Portal.Entra.Directory
    has_many :entra_auth_providers, Portal.Entra.AuthProvider

    has_many :oidc_auth_providers, Portal.OIDC.AuthProvider
    has_one :email_otp_auth_provider, Portal.EmailOTP.AuthProvider
    has_one :userpass_auth_provider, Portal.Userpass.AuthProvider

    # Billing limit exceeded flags - set by CheckAccountLimits worker and Stripe event processing
    field :users_limit_exceeded, :boolean, default: false
    field :seats_limit_exceeded, :boolean, default: false
    field :service_accounts_limit_exceeded, :boolean, default: false
    field :sites_limit_exceeded, :boolean, default: false
    field :admins_limit_exceeded, :boolean, default: false

    # Tracks when the last limit exceeded email was sent (for throttling)
    field :warning_last_sent_at, :utc_datetime_usec

    field :disabled_reason, :string
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_length(:name, min: 3, max: 64)
    |> validate_length(:slug, min: 3, max: 100)
    |> validate_length(:legal_name, min: 1, max: 255)
    |> unique_constraint(:slug, name: :accounts_slug_index)
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{disabled_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  Returns true if any billing limit is exceeded.
  """
  @spec any_limit_exceeded?(t()) :: boolean()
  def any_limit_exceeded?(%__MODULE__{} = account) do
    account.users_limit_exceeded or
      account.seats_limit_exceeded or
      account.service_accounts_limit_exceeded or
      account.sites_limit_exceeded or
      account.admins_limit_exceeded
  end

  @doc """
  Builds a human-readable warning message from the exceeded limit flags.
  Returns nil if no limits are exceeded.
  """
  @spec build_limits_exceeded_message(t()) :: String.t() | nil
  def build_limits_exceeded_message(%__MODULE__{} = account) do
    limits =
      []
      |> maybe_add("users", account.users_limit_exceeded)
      |> maybe_add("monthly active users", account.seats_limit_exceeded)
      |> maybe_add("service accounts", account.service_accounts_limit_exceeded)
      |> maybe_add("sites", account.sites_limit_exceeded)
      |> maybe_add("account admins", account.admins_limit_exceeded)

    case limits do
      [] -> nil
      limits -> "You have exceeded the following limits: #{Enum.join(limits, ", ")}"
    end
  end

  defp maybe_add(list, label, true), do: list ++ [label]
  defp maybe_add(list, _label, false), do: list

  for feature <- Portal.Accounts.Features.__schema__(:fields) do
    def unquote(:"#{feature}_enabled?")(account) do
      Config.global_feature_enabled?(unquote(feature)) and
        account_feature_enabled?(account, unquote(feature))
    end
  end

  defp account_feature_enabled?(account, feature) do
    Map.fetch!(account.features || %Portal.Accounts.Features{}, feature) || false
  end
end

defmodule Portal.Account.Metadata do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    embeds_one :stripe, Portal.Account.Metadata.Stripe, on_replace: :update
  end

  def changeset(metadata \\ %__MODULE__{}, attrs) do
    metadata
    |> cast(attrs, [])
    |> cast_embed(:stripe, with: &Portal.Account.Metadata.Stripe.changeset/2)
  end
end

defmodule Portal.Account.Metadata.Stripe do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :customer_id, :string
    field :subscription_id, :string
    field :product_name, :string
    field :billing_email, :string
    field :trial_ends_at, :utc_datetime_usec
    field :support_type, :string
  end

  def changeset(stripe \\ %__MODULE__{}, attrs) do
    stripe
    |> cast(attrs, [
      :customer_id,
      :subscription_id,
      :product_name,
      :billing_email,
      :trial_ends_at,
      :support_type
    ])
  end
end
