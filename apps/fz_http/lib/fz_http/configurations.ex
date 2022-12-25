defmodule FzHttp.Configurations do
  @moduledoc """
  The Conf context for app configurations.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset
  import Wrapped.Cache
  alias FzHttp.{Repo, Configurations.Configuration}

  def get_configuration! do
    Repo.one!(Configuration)
  end

  def auto_create_users?(field, provider) do
    cache().get!(field)
    |> Map.get(provider)
    |> Map.get("auto_create_users")
  end

  def change_configuration(%Configuration{} = config \\ get_configuration!()) do
    Configuration.changeset(config, %{})
  end

  def update_configuration(%Configuration{} = config \\ get_configuration!(), attrs) do
    config
    |> Configuration.changeset(attrs)
    |> prepare_changes(fn changeset ->
      changeset.changes |> Enum.each(&put_cache/1)
      changeset
    end)
    |> Repo.update()
  end

  defp put_cache({:openid_connect_providers = key, val}) do
    FzHttp.OIDC.StartProxy.restart()
    cache().put!(key, val)
  end

  defp put_cache({:saml_identity_providers = key, val}) do
    FzHttp.SAML.StartProxy.restart()
    cache().put!(key, val)
  end

  # nested changeset values
  defp put_cache({key, %Ecto.Changeset{} = val}), do: cache().put!(key, val.changes)
  defp put_cache({key, val}), do: cache().put!(key, val)

  def logo_types, do: ~w(Default URL Upload)

  def logo_type(nil), do: "Default"
  def logo_type(%{url: _url}), do: "URL"
  def logo_type(%{data: _data}), do: "Upload"
end
