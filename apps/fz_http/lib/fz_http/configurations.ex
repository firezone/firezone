defmodule FzHttp.Configurations do
  @moduledoc """
  The Conf context for app configurations.
  """
  import Ecto.Query, warn: false
  alias FzHttp.{Repo, Configurations.Configuration}

  def get!(key) do
    Map.get(get_configuration!(), key)
  end

  def fetch_oidc_provider_config(provider_id) do
    get!(:openid_connect_providers)
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil ->
        {:error, :not_found}

      provider ->
        external_url = FzHttp.Config.fetch_env!(:fz_http, :external_url)

        {:ok,
         %{
           discovery_document_uri: provider.discovery_document_uri,
           client_id: provider.client_id,
           client_secret: provider.client_secret,
           redirect_uri:
             provider.redirect_uri || "#{external_url}/auth/oidc/#{provider.id}/callback/",
           response_type: provider.response_type,
           scope: provider.scope
         }}
    end
  end

  def put!(key, val) do
    configuration =
      get_configuration!()
      |> Configuration.changeset(%{key => val})
      |> Repo.update!()

    FzHttp.SAML.StartProxy.refresh(configuration.saml_identity_providers)

    configuration
  end

  def get_configuration! do
    Repo.one!(Configuration)
  end

  def auto_create_users?(field, provider_id) do
    FzHttp.Configurations.get!(field)
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> raise RuntimeError, "Unknown provider #{provider_id}"
      provider -> provider.auto_create_users
    end
  end

  def new_configuration(attrs \\ %{}) do
    Configuration.changeset(%Configuration{}, attrs)
  end

  def change_configuration(%Configuration{} = config \\ get_configuration!()) do
    Configuration.changeset(config, %{})
  end

  def update_configuration(%Configuration{} = config \\ get_configuration!(), attrs) do
    case Repo.update(Configuration.changeset(config, attrs)) do
      {:ok, configuration} ->
        FzHttp.SAML.StartProxy.refresh(configuration.saml_identity_providers)

        {:ok, configuration}

      error ->
        error
    end
  end

  def logo_types, do: ~w(Default URL Upload)

  def logo_type(nil), do: "Default"
  def logo_type(%{url: url}) when not is_nil(url), do: "URL"
  def logo_type(%{data: data}) when not is_nil(data), do: "Upload"

  def vpn_sessions_expire? do
    freq = vpn_duration()
    freq > 0 && freq < Configuration.max_vpn_session_duration()
  end

  def vpn_duration do
    get_configuration!().vpn_session_duration
  end
end
