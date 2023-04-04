defmodule Web.JSON.OpenIDConnectProviderView do
  use Web, :view

  @keys_to_render ~w[
    id
    label
    scope
    response_type
    client_id
    client_secret
    discovery_document_uri
    redirect_uri
    auto_create_users
  ]a
  def render("openid_connect_provider.json", %{open_id_connect_provider: openid_connect_provider}) do
    Map.take(openid_connect_provider, @keys_to_render)
  end
end
