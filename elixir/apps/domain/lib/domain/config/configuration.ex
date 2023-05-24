defmodule Domain.Config.Configuration do
  use Domain, :schema
  alias Domain.Config.Logo

  schema "configurations" do
    field :devices_upstream_dns, {:array, :string}, default: []

    embeds_one :logo, Logo, on_replace: :delete

    belongs_to :account, Domain.Accounts.Account

    timestamps()
  end
end
