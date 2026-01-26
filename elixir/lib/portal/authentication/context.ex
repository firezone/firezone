defmodule Portal.Authentication.Context do
  @typedoc """
  This structure represents an authentication context for a user or an API token.

  Context is then used in the audit logging to persist additional metadata about
  the client and IP address used to perform the action.
  """
  @type t :: %__MODULE__{
          type: :portal | :client | :relay | :gateway | :api_client,
          remote_ip: :inet.ip_address(),
          remote_ip_location_region: String.t(),
          remote_ip_location_city: String.t(),
          remote_ip_location_lat: float(),
          remote_ip_location_lon: float(),
          user_agent: String.t()
        }

  @enforce_keys [:type, :remote_ip, :user_agent]
  defstruct type: nil,
            remote_ip: nil,
            remote_ip_location_region: nil,
            remote_ip_location_city: nil,
            remote_ip_location_lat: nil,
            remote_ip_location_lon: nil,
            user_agent: nil

  alias Portal.Geo

  def build(remote_ip, user_agent, headers, type) do
    {region, city, {lat, lon}} = Geo.locate(remote_ip, headers)

    %__MODULE__{
      type: type,
      user_agent: user_agent,
      remote_ip: remote_ip,
      remote_ip_location_region: region,
      remote_ip_location_city: city,
      remote_ip_location_lat: lat,
      remote_ip_location_lon: lon
    }
  end
end
