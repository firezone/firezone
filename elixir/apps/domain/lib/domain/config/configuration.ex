defmodule Domain.Config.Configuration do
  use Domain, :schema
  alias Domain.Config.Logo

  schema "configurations" do
    embeds_many :clients_upstream_dns, ClientsUpstreamDNS, on_replace: :delete, primary_key: false do
      field :address, :string
    end

    embeds_one :logo, Logo, on_replace: :delete

    belongs_to :account, Domain.Accounts.Account

    timestamps()
  end
end
