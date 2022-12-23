defmodule FzHttp.SAML.StartProxy do
  @moduledoc """
  This proxy starts Samly.Provider with proper configs
  (after `FzHttp.Conf.Cache` has started)
  """

  import Actual.Cache

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(_) do
    samly = Samly.Provider.start_link()

    FzHttp.Config.fetch_env!(:samly, Samly.Provider)
    |> set_service_provider()
    |> set_identity_providers()
    |> refresh()

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

  def set_identity_providers(samly_configs, providers \\ cache().get!(:saml_identity_providers)) do
    external_url = FzHttp.Config.fetch_env!(:fz_http, :external_url)

    identity_providers =
      providers
      |> Enum.map(fn {id, setting} ->
        %{
          id: id,
          sp_id: "firezone",
          metadata: Map.get(setting, "metadata"),
          base_url: Map.get(setting, "base_url", Path.join(external_url, "/auth/saml")),
          sign_requests: Map.get(setting, "sign_requests", true),
          sign_metadata: Map.get(setting, "sign_metadata", true),
          signed_assertion_in_resp: Map.get(setting, "signed_assertion_in_resp", true),
          signed_envelopes_in_resp: Map.get(setting, "signed_envelopes_in_resp", true)
        }
      end)

    Keyword.put(samly_configs, :identity_providers, identity_providers)
  end

  def refresh(samly_configs) do
    Application.put_env(:samly, Samly.Provider, samly_configs)
    Samly.Provider.refresh_providers()
  end
end
