defmodule FzHttp.OIDCConfigFixtures do
  @moduledoc """
  Fixtures for OIDC configs.
  """

  def oidc_attrs do
    %{
      "discovery_document_uri" => "https://okta/.well-known/openid-configuration",
      "client_id" => "okta-client-id",
      "client_secret" => "okta-client-secret",
      "redirect_uri" => "https://localhost",
      "id" => "okta",
      "label" => "Okta",
      "scope" => "openid profile email",
      "response_type" => "code",
      "auto_create_users" => true
    }
  end
end
