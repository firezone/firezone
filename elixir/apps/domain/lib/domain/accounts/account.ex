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
    has_many :actors, Domain.Actors.Actor
    has_many :actor_group_memberships, Domain.Actors.Membership
    has_many :actor_groups, Domain.Actors.Group

    has_many :auth_providers, Domain.Auth.Provider
    has_many :auth_identities, Domain.Auth.Identity

    has_many :network_addresses, Domain.Network.Address

    has_many :policies, Domain.Policies.Policy

    has_many :flows, Domain.Flows.Flow

    has_many :resources, Domain.Resources.Resource
    has_many :resource_connections, Domain.Resources.Connection

    has_many :clients, Domain.Clients.Client

    has_many :gateways, Domain.Gateways.Gateway
    has_many :gateway_groups, Domain.Gateways.Group

    has_many :relays, Domain.Relays.Relay
    has_many :relay_groups, Domain.Relays.Group

    has_many :tokens, Domain.Tokens.Token

    field :warning, :string
    field :warning_delivery_attempts, :integer, default: 0
    field :warning_last_sent_at, :utc_datetime_usec

    field :disabled_reason, :string
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end
end
