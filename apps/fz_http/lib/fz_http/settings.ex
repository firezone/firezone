defmodule FzHttp.Settings do
  @moduledoc """
  The Settings context.
  """

  import FzHttp.Macros
  import Ecto.Query, warn: false
  import FzCommon.FzInteger, only: [max_pg_integer: 0]
  alias FzHttp.Repo

  alias FzHttp.Settings.Setting

  def_settings(~w(
    default.device.allowed_ips
    default.device.dns_servers
    default.device.endpoint
    default.device.persistent_keepalives
    security.require_auth_for_vpn_frequency
  ))

  @doc """
  Returns the list of settings.

  ## Examples

      iex> list_settings()
      [%Setting{}, ...]

  """
  def list_settings do
    Repo.all(Setting)
  end

  @doc """
  Gets a single setting by its ID.

  Raises `Ecto.NoResultsError` if the Setting does not exist.

  ## Examples

      iex> get_setting!(123)
      %Setting{}

      iex> get_setting!(456)
      ** (Ecto.NoResultsError)

  """
  def get_setting!(key: key) do
    Repo.one!(from s in Setting, where: s.key == ^key)
  end

  def get_setting!(id), do: Repo.get!(Setting, id)

  @doc """
  Updates a setting.

  ## Examples

      iex> update_setting(setting, %{field: new_value})
      {:ok, %Setting{}}

      iex> update_setting(setting, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_setting(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  def update_setting(key, value) when is_binary(key) do
    get_setting!(key: key)
    |> update_setting(%{value: value})
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking setting changes.

  ## Examples

      iex> change_setting(setting)
      %Ecto.Changeset{data: %Setting{}}

  """
  def change_setting(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs)
  end

  @doc """
  Returns a list of all the settings beginning with the specified key prefix.
  """
  def to_list(prefix \\ "") do
    starts_with = prefix <> "%"
    Repo.all(from s in Setting, where: ilike(s.key, ^starts_with))
  end

  def vpn_sessions_expire? do
    freq = String.to_integer(security_require_auth_for_vpn_frequency())
    freq > 0 && freq < max_pg_integer()
  end
end
