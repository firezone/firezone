defmodule Domain.Accounts.Account do
  use Domain, :schema

  schema "accounts" do
    field :name, :string
    field :slug, :string

    field :legal_name, :string

    # Updated by the billing subscription metadata fields
    embeds_one :features, Domain.Accounts.Features, on_replace: :delete
    embeds_one :limits, Domain.Accounts.Limits, on_replace: :delete
    embeds_one :config, Domain.Accounts.Config, on_replace: :update

    embeds_one :metadata, Metadata, primary_key: false, on_replace: :update do
      embeds_one :stripe, Stripe, primary_key: false, on_replace: :update do
        field :customer_id, :string
        field :subscription_id, :string
        field :product_name, :string
        field :billing_email, :string
        field :trial_ends_at, :utc_datetime_usec
        field :support_type, :string
      end
    end

    # We mention all schemas here to leverage Ecto compile-time reference checks,
    # because later we will have to shard data by account_id.
    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :actors, Domain.Actors.Actor, where: [deleted_at: nil]
    has_many :actor_group_memberships, Domain.Actors.Membership, where: [deleted_at: nil]
    has_many :actor_groups, Domain.Actors.Group, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :legacy_auth_providers, Domain.Auth.Provider, where: [deleted_at: nil]
    has_many :auth_identities, Domain.Auth.Identity, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :network_addresses, Domain.Network.Address, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :policies, Domain.Policies.Policy, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :flows, Domain.Flows.Flow, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :resources, Domain.Resources.Resource, where: [deleted_at: nil]
    has_many :resource_connections, Domain.Resources.Connection, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :clients, Domain.Clients.Client, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :gateways, Domain.Gateways.Gateway, where: [deleted_at: nil]
    has_many :gateway_groups, Domain.Gateways.Group, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :relays, Domain.Relays.Relay, where: [deleted_at: nil]
    has_many :relay_groups, Domain.Relays.Group, where: [deleted_at: nil]

    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :tokens, Domain.Tokens.Token, where: [deleted_at: nil]

    has_many :google_directories, Domain.Google.Directory
    has_many :google_auth_providers, Domain.Google.AuthProvider
    has_many :okta_directories, Domain.Okta.Directory
    has_many :auth_providers, Domain.AuthProviders.AuthProvider
    has_many :okta_auth_providers, Domain.Okta.AuthProvider
    has_many :entra_directories, Domain.Entra.Directory
    has_many :entra_auth_providers, Domain.Entra.AuthProvider

    has_many :oidc_auth_providers, Domain.OIDC.AuthProvider
    has_one :email_auth_provider, Domain.Email.AuthProvider
    has_one :userpass_auth_provider, Domain.Userpass.AuthProvider

    field :warning, :string
    field :warning_delivery_attempts, :integer, default: 0
    field :warning_last_sent_at, :utc_datetime_usec

    field :disabled_reason, :string
    field :disabled_at, :utc_datetime_usec

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
