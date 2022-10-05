defmodule FzHttp.Configurations do
  @moduledoc """
  The Conf context for app configurations.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset
  alias FzHttp.{Repo, Configurations.Configuration, Configurations.Cache}

  defdelegate get(key), to: FzHttp.Configurations.Cache
  defdelegate get!(key), to: FzHttp.Configurations.Cache

  def get_configuration! do
    Repo.one!(Configuration)
  end

  def change_configuration(%Configuration{} = config \\ get_configuration!()) do
    Configuration.changeset(config, %{})
  end

  def update_configuration(%Configuration{} = config \\ get_configuration!(), attrs) do
    config
    |> Configuration.changeset(attrs)
    |> prepare_changes(fn changeset ->
      for {k, v} <- changeset.changes do
        case v do
          %Ecto.Changeset{} ->
            Cache.put!(k, v.changes)

          _ ->
            Cache.put!(k, v)
        end
      end

      changeset
    end)
    |> Repo.update()
  end

  def logo_types, do: ~w(Default URL Upload)

  def logo_type(nil), do: "Default"
  def logo_type(%{url: _url}), do: "URL"
  def logo_type(%{data: _data}), do: "Upload"
end
