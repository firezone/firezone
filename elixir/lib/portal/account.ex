defmodule Portal.Account do
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__.Database

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :key, :string

    has_many :slugs, Portal.AccountSlug

    field :legal_name, :string

    # Per-account symmetric key used to sign and verify flow-log ingest tokens.
    # DB-generated and redacted; see Portal.FlowLogToken.
    field :ingest_signing_key, :binary, read_after_writes: true, redact: true

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
    has_many :pending_identities, Portal.PendingIdentity
    has_many :trust_anchors, Portal.TrustAnchor
    has_many :trust_anchor_certificates, Portal.TrustAnchorCertificate

    has_many :policies, Portal.Policy

    has_many :policy_authorizations, Portal.PolicyAuthorization

    has_many :resources, Portal.Resource

    has_many :devices, Portal.Device
    has_many :posture_providers, Portal.PostureProvider
    has_many :intune_posture_providers, Portal.Intune.PostureProvider
    has_many :intune_devices, Portal.Intune.Device
    has_many :iru_posture_providers, Portal.Iru.PostureProvider
    has_many :iru_devices, Portal.Iru.Device
    has_many :defender_posture_providers, Portal.Defender.PostureProvider
    has_many :defender_devices, Portal.Defender.Device
    has_many :santa_posture_providers, Portal.Santa.PostureProvider
    has_many :santa_devices, Portal.Santa.Device
    has_many :sentinelone_posture_providers, Portal.SentinelOne.PostureProvider
    has_many :sentinelone_devices, Portal.SentinelOne.Device
    has_many :sophos_posture_providers, Portal.Sophos.PostureProvider
    has_many :sophos_devices, Portal.Sophos.Device
    has_many :clients, Portal.Device, where: [type: :client]
    has_many :gateways, Portal.Device, where: [type: :gateway]
    has_many :sites, Portal.Site

    has_many :client_tokens, Portal.ClientToken
    has_many :gateway_tokens, Portal.GatewayToken
    has_many :one_time_passcodes, Portal.OneTimePasscode

    has_many :google_directories, Portal.Google.Directory
    has_many :google_auth_providers, Portal.Google.AuthProvider
    has_many :github_auth_providers, Portal.GitHub.AuthProvider
    has_many :okta_directories, Portal.Okta.Directory
    has_many :okta_auth_providers, Portal.Okta.AuthProvider
    has_many :entra_directories, Portal.Entra.Directory
    has_many :entra_auth_providers, Portal.Entra.AuthProvider

    has_many :oidc_auth_providers, Portal.OIDC.AuthProvider
    has_one :email_otp_auth_provider, Portal.EmailOTP.AuthProvider
    has_one :userpass_auth_provider, Portal.Userpass.AuthProvider
    has_one :x509_auth_provider, Portal.X509.AuthProvider

    # Billing limit exceeded flags - set by CheckAccountLimits worker and Stripe event processing
    field :users_limit_exceeded, :boolean, default: false
    field :seats_limit_exceeded, :boolean, default: false
    field :service_accounts_limit_exceeded, :boolean, default: false
    field :sites_limit_exceeded, :boolean, default: false
    field :admins_limit_exceeded, :boolean, default: false

    # Tracks when the last limit exceeded email was sent (for throttling)
    field :warning_last_sent_at, :utc_datetime_usec

    # Tracks the last seat warning email sent (Business plan): when, and which
    # state it described, so a worse state is not held back by the weekly throttle
    field :seats_warning_last_sent_at, :utc_datetime_usec
    field :outdated_gateway_last_sent_at, :utc_datetime_usec
    field :seats_warning_level, Ecto.Enum, values: [:approaching, :at_limit, :over]

    field :disabled_reason, :string
    field :is_disabled, :boolean, default: false, read_after_writes: true

    field :scheduled_deletion_at, :utc_datetime_usec

    # Set by Ops Admins only. Prevents account admins from modifying account settings.
    field :lock_enabled_at, :utc_datetime_usec

    # Usage against `limits`, computed by the REST API when it renders the account.
    field :limit_usage, :map, virtual: true

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_length(:name, min: 3, message: "too short")
    |> validate_length(:name, max: 64, message: "too long")
    |> validate_length(:slug, min: 3, max: 100)
    |> validate_length(:key, is: 6)
    |> validate_key_format()
    |> validate_length(:legal_name, min: 1, max: 255)
    |> unique_constraint(:slug, name: :accounts_slug_index)
    |> unique_constraint(:key, name: :accounts_key_index)
    |> prepare_changes(&register_slug/1)
  end

  @base36 ~c"abcdefghijklmnopqrstuvwxyz0123456789"

  @doc "Generate a cryptographically random 6-character base-36 key."
  def new_key do
    for(_ <- 1..6, into: "", do: <<Enum.at(@base36, uniform(36))>>)
  end

  # Rejection sampling to avoid modulo bias.
  # Largest multiple of 36 that fits in a byte is 252 (36 * 7).
  defp uniform(n) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    if byte < 252 do
      rem(byte, n)
    else
      uniform(n)
    end
  end

  defp validate_key_format(changeset) do
    validate_format(changeset, :key, ~r/^[a-z0-9]+$/, message: "must be lowercase alphanumeric")
  end

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{is_disabled: false}), do: true
  def active?(%__MODULE__{}), do: false

  @spec pending_deletion?(t()) :: boolean()
  def pending_deletion?(%__MODULE__{scheduled_deletion_at: nil}), do: false
  def pending_deletion?(%__MODULE__{}), do: true

  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{lock_enabled_at: nil}), do: false
  def locked?(%__MODULE__{}), do: true

  # sobelow_skip ["DOS.BinToAtom"]
  for feature <- Portal.Accounts.Features.__schema__(:fields) do
    def unquote(:"#{feature}_enabled?")(account) do
      account_feature_enabled?(account, unquote(feature))
    end
  end

  defp account_feature_enabled?(account, feature) do
    Map.fetch!(account.features || %Portal.Accounts.Features{}, feature) || false
  end

  # Every slug an account uses is kept in account_slugs so that old slugs keep
  # redirecting and no other account can take them. Runs inside the insert or
  # update transaction, so a lost race on the slug rolls the whole change back.
  defp register_slug(changeset) do
    case fetch_change(changeset, :slug) do
      {:ok, slug} when is_binary(slug) -> register_slug(changeset, slug)
      _ -> changeset
    end
  end

  defp register_slug(changeset, slug) do
    account_id = get_field(changeset, :id)

    case Database.slug_owner_id(changeset.repo, slug) do
      nil -> insert_slug(changeset, slug)
      ^account_id -> changeset
      _other_account_id -> add_error(changeset, :slug, "has already been taken")
    end
  end

  # The account row does not exist yet on insert, so the slug row goes in as a
  # child of the account instead of ahead of it.
  defp insert_slug(%Ecto.Changeset{action: :insert} = changeset, slug) do
    slug_changeset =
      %Portal.AccountSlug{}
      |> change(%{slug: slug})
      |> Portal.AccountSlug.changeset()

    put_assoc(changeset, :slugs, [slug_changeset])
  end

  defp insert_slug(changeset, slug) do
    case Database.insert_slug(changeset.repo, get_field(changeset, :id), slug) do
      {:ok, _account_slug} -> changeset
      {:error, _slug_changeset} -> add_error(changeset, :slug, "has already been taken")
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def slug_owner_id(repo, slug) do
      Safe.one(repo, from(s in Portal.AccountSlug, where: s.slug == ^slug, select: s.account_id))
    end

    def insert_slug(repo, account_id, slug) do
      slug_changeset =
        Ecto.Changeset.change(%Portal.AccountSlug{}, %{account_id: account_id, slug: slug})

      Safe.insert(repo, slug_changeset)
    end
  end
end

defmodule Portal.Account.Metadata do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :marketing_attribution, :map
    embeds_one :stripe, Portal.Account.Metadata.Stripe, on_replace: :update
  end

  def changeset(metadata \\ %__MODULE__{}, attrs) do
    metadata
    |> cast(attrs, [:marketing_attribution])
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
    field :subscription_status, :string
    field :product_name, :string
    field :billing_email, :string
    field :trial_ends_at, :utc_datetime_usec
    field :support_type, :string
    embeds_many :add_ons, Portal.Account.Metadata.Stripe.AddOn, on_replace: :delete
  end

  def changeset(stripe \\ %__MODULE__{}, attrs) do
    stripe
    |> cast(attrs, [
      :customer_id,
      :subscription_id,
      :subscription_status,
      :product_name,
      :billing_email,
      :trial_ends_at,
      :support_type
    ])
    |> cast_embed(:add_ons, with: &Portal.Account.Metadata.Stripe.AddOn.changeset/2)
  end
end

defmodule Portal.Account.Metadata.Stripe.AddOn do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :quantity, :integer
    field :limit, :string
  end

  def changeset(add_on \\ %__MODULE__{}, attrs) do
    cast(add_on, attrs, [:name, :quantity, :limit])
  end
end
