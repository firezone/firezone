defmodule FzHttp.SAML.StartProxy do
  @moduledoc """
  This proxy starts Samly.Provider with proper configs
  """

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(:test) do
    start_link(nil)
  end

  def start_link(_) do
    samly = Samly.Provider.start_link()

    refresh()

    samly
  end

  def set_service_provider(samly_configs) do
    entity_id = FzHttp.Config.fetch_env!(:fz_http, :saml_entity_id)
    keyfile = FzHttp.Config.fetch_env!(:fz_http, :saml_keyfile_path)
    certfile = FzHttp.Config.fetch_env!(:fz_http, :saml_certfile_path)

    # Only one service provider definition: us.
    Keyword.put(samly_configs, :service_providers, [
      %{
        id: "firezone",
        entity_id: entity_id,
        certfile: certfile,
        keyfile: keyfile
      }
    ])
  end

  def set_identity_providers(samly_configs, providers) do
    identity_providers =
      providers
      |> Enum.map(fn provider ->
        %{
          id: provider.id,
          sp_id: "firezone",
          metadata: provider.metadata,
          base_url: provider.base_url,
          sign_requests: provider.sign_requests,
          sign_metadata: provider.sign_metadata,
          signed_assertion_in_resp: provider.signed_assertion_in_resp,
          signed_envelopes_in_resp: provider.signed_envelopes_in_resp
        }
      end)

    Keyword.put(samly_configs, :identity_providers, identity_providers)
  end

  def refresh(providers \\ FzHttp.Config.fetch_config!(:saml_identity_providers)) do
    samly_configs =
      FzHttp.Config.fetch_env!(:samly, Samly.Provider)
      |> set_service_provider()
      |> set_identity_providers(providers)

    Application.put_env(:samly, Samly.Provider, samly_configs)
    Samly.Provider.refresh_providers()
  end
end
