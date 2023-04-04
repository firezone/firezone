defmodule Web.JSON.SAMLIdentityProviderView do
  use Web, :view

  @keys_to_render ~w[
    id
    label
    base_url
    metadata
    sign_requests
    sign_metadata
    signed_assertion_in_resp
    signed_envelopes_in_resp
    auto_create_users
  ]a
  def render("saml_identity_provider.json", %{saml_identity_provider: saml_identity_provider}) do
    Map.take(saml_identity_provider, @keys_to_render)
  end
end
