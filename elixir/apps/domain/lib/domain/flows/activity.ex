defmodule Domain.Flows.Activity do
  use Domain, :schema

  schema "flow_activities" do
    field :window_started_at, :utc_datetime_usec
    field :window_ended_at, :utc_datetime_usec

    field :destination, Domain.Types.IPPort
    field :rx_bytes, :integer
    field :tx_bytes, :integer

    belongs_to :flow, Domain.Flows.Flow
    belongs_to :account, Domain.Accounts.Account
  end
end
