defmodule FzHttp.Configurations.Cache do
  @moduledoc """
  Manipulate cached configurations.
  """

  use GenServer, restart: :transient

  alias FzHttp.Configurations

  @name :conf

  def get(key) do
    Cachex.get(@name, key)
  end

  def get!(key) do
    Cachex.get!(@name, key)
  end

  def put(key, value) do
    Cachex.put(@name, key, value)
  end

  def put!(key, value) do
    Cachex.put!(@name, key, value)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  # List of fields not in Application.env
  #
  # Currently only applies to:
  #
  # allow_unprivileged_device_management
  # allow_unprivileged_device_configuration
  # local_auth_enabled
  # openid_connect_providers
  # saml_identity_providers
  # disable_vpn_on_oidc_error
  #
  # XXX: This will be deleted when the Cache is removed.
  @no_fallback ~w(
    logo
    default_client_endpoint
    default_client_mtu
    default_client_allowed_ips
    default_client_dns
    default_client_persistent_keepalive
    vpn_session_duration
  )a

  @impl true
  def init(_) do
    configurations =
      Configurations.get_configuration!()
      |> Map.from_struct()
      |> Map.delete(:id)

    for {k, v} <- configurations do
      # XXX: Remove fallbacks before 1.0?
      v =
        with nil <- v, true <- k not in @no_fallback do
          FzHttp.Config.fetch_env!(:fz_http, k)
        else
          _ -> v
        end

      {:ok, _} = put(k, v)
    end

    :ignore
  end
end
