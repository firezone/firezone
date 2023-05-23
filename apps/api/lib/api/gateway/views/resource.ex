defmodule API.Gateway.Views.Resource do
  alias Domain.Resources

  def render(%Resources.Resource{} = resource) do
    %{
      id: resource.id,
      address: resource.address,
      ipv4: resource.ipv4,
      ipv6: resource.ipv6
    }
  end
end
