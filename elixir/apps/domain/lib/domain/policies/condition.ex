defmodule Domain.Policies.Condition do
  use Domain, :schema

  @type t :: %__MODULE__{
          property:
            :remote_ip_location_region
            | :remote_ip
            | :provider_id
            | :current_utc_datetime
            | :client_verified,
          operator:
            :contains
            | :does_not_contain
            | :is_in
            | :is_not_in
            | :is_in_day_of_week_time_ranges
            | :is_in_cidr
            | :is_not_in_cidr
            | :is,
          values: [String.t()]
        }

  @primary_key false
  embedded_schema do
    field :property, Ecto.Enum, values: ~w[
        remote_ip_location_region
        remote_ip
        provider_id
        current_utc_datetime
        client_verified
      ]a

    field :operator, Ecto.Enum, values: ~w[
        contains does_not_contain
        is_in is_not_in
        is_in_day_of_week_time_ranges
        is_in_cidr is_not_in_cidr
        is
      ]a

    field :values, {:array, :string}
  end
end
