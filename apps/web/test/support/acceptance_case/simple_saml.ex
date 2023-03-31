defmodule FzHttpWeb.AcceptanceCase.SimpleSAML do
  @endpoint "http://localhost:8400"

  def fetch_metadata!(endpoint) do
    metadata_url = "#{endpoint}/simplesaml/saml2/idp/metadata.php"
    {:ok, 200, _headers, metadata} = :hackney.request(:get, metadata_url, [], "", [:with_body])
    metadata
  end

  def setup_saml_provider(attrs_overrides \\ %{}) do
    metadata = fetch_metadata!(@endpoint)

    FzHttp.Config.put_config!(:saml_identity_providers, [
      %{
        "id" => "mysamlidp",
        "label" => "test-saml-idp",
        "auto_create_users" => true,
        "sign_requests" => true,
        "sign_metadata" => true,
        "signed_assertion_in_resp" => true,
        "signed_envelopes_in_resp" => true,
        "metadata" => metadata
      }
      |> Map.merge(attrs_overrides)
    ])

    :ok
  end
end
