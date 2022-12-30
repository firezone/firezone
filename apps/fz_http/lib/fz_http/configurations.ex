defmodule FzHttp.Configurations do
  @moduledoc """
  The Conf context for app configurations.
  """

  import Ecto.Query, warn: false

  alias FzHttp.{Repo, Configurations.Configuration}

  def get!(key) do
    Map.get(get_configuration!(), key)
  end

  def put!(key, val) do
    get_configuration!()
    |> Configuration.changeset(%{key => val})
    |> Repo.update!()
  end

  def get_configuration! do
    Repo.one!(Configuration)
  end

  def get_provider_by_id(field, provider_id) do
    FzHttp.Configurations.get!(field)
    |> Enum.find(&(&1.id == provider_id))
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
        {:ok, _pid} = FzHttp.SAML.StartProxy.restart()
        {:ok, _pid} = FzHttp.OIDC.StartProxy.restart()

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
