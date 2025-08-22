defmodule Domain.Cache.Cacheable.Policy do
  defstruct [
    :id,
    :resource_id,
    :actor_group_id,
    :conditions
  ]

  @type condition :: %{
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

  @type t :: %__MODULE__{
          id: Domain.Cache.Cacheable.uuid_binary(),
          resource_id: Domain.Cache.Cacheable.uuid_binary(),
          actor_group_id: Domain.Cache.Cacheable.uuid_binary(),
          conditions: [condition()]
        }
end
