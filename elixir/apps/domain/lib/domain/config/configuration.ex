defmodule Domain.Config.Configuration do
  use Domain, :schema
  alias Domain.Config.Logo
  alias Domain.Config.Configuration.ClientsUpstreamDNS

  schema "configurations" do
    embeds_many :clients_upstream_dns, ClientsUpstreamDNS, on_replace: :delete
    embeds_one :logo, Logo, on_replace: :delete

    belongs_to :account, Domain.Accounts.Account

    timestamps()
  end
end
