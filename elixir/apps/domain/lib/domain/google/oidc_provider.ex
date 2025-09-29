defmodule Domain.Google.OIDCProvider do
  use Domain, :schema
  alias Domain.Accounts.Account

  @primary_key false
  schema "google_oidc_providers" do
    belongs_to :account, Account, primary_key: true
    field :hosted_domain, :string

    field :created_by, Ecto.Enum, values: ~w[actor identity]a
    field :created_by_subject, :map
    timestamps()
  end
end
