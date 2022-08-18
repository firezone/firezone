defmodule FzHttp.SAML.StartProxy do
  @moduledoc """
  This proxy starts Samly.Provider with proper configs
  (after `FzHttp.Conf.Cache` has started)
  """

  alias FzHttp.Conf

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}
  end

  def start_link(_) do
    samly = Samly.Provider.start_link()

    Application.fetch_env!(:samly, Samly.Provider)
    |> set_service_provider()
    |> set_identity_providers()
    |> refresh()

    samly
  end

  def set_service_provider(samly_configs) do
    Keyword.put(samly_configs, :service_providers, [
      %{
        id: "firezone",
        entity_id: "urn:firezone.dev:firezone-app",
        certfile: Path.join(:code.priv_dir(:fz_http), "cert/selfsigned.pem"),
        keyfile: Path.join(:code.priv_dir(:fz_http), "cert/selfsigned_key.pem")
      }
    ])
  end

  def set_identity_providers(samly_configs, providers \\ Conf.get(:saml_identity_providers)) do
    external_url = Application.fetch_env!(:fz_http, :external_url)

    identity_providers =
      for {id, setting} <- providers do
        %{
          id: id,
          sp_id: "firezone",
          metadata: setting["metadata"],
          base_url: Path.join(external_url, "/auth/saml")
        }
      end

    Keyword.put(samly_configs, :identity_providers, identity_providers)
  end

  def refresh(samly_configs) do
    Application.put_env(:samly, Samly.Provider, samly_configs)
    Samly.Provider.refresh_providers()
  end
end
