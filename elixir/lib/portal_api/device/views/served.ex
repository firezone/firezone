defmodule PortalAPI.Device.Views.Served do
  @moduledoc """
  The inbound view on the unified protocol: the sites a device serves and
  the resources behind them, as the device needs them to answer for those
  resources.
  """

  alias Portal.Cache.Cacheable

  @doc "The sites the device serves, by id and name."
  @spec render_sites([Portal.Site.t()]) :: [map()]
  def render_sites(sites) do
    Enum.map(sites, &%{id: &1.id, name: &1.name})
  end

  @doc "A resource one of the device's sites serves, in the shape a serving device parses."
  @spec render_resource(Portal.Resource.t()) :: map()
  def render_resource(%Portal.Resource{} = resource) do
    resource
    |> Cacheable.to_cache()
    |> PortalAPI.Gateway.Views.Resource.render()
    |> Map.put(:site_id, resource.site_id)
  end
end
