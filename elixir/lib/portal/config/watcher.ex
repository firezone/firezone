defmodule Portal.Config.Watcher do
  @moduledoc """
  Applies `live` App Configuration changes to the running node.

  Every minute it reads the store again. When only `live` settings changed, it
  evaluates `config/runtime.exs` with the old settings and with the new ones,
  and puts only the application environment entries that differ between those
  two. Entries changed by hand from the remote console are left alone unless
  the new settings change them too. When any `boot` setting changed, it applies
  nothing and waits for the next restart.

  If the new settings do not evaluate, the node keeps the old ones.

  Live changes only reach code that reads its configuration when it uses it.
  """
  use GenServer
  require Logger

  @interval :timer.minutes(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      fetch: Keyword.get(opts, :fetch, &Portal.Config.fetch_azure_settings!/0),
      get_settings: Keyword.get(opts, :get_settings, &Portal.Config.azure_settings/0),
      put_settings: Keyword.get(opts, :put_settings, &Portal.Config.put_azure_settings/1),
      read_config: Keyword.get(opts, :read_config, &read_runtime_config/0),
      interval: Keyword.get(opts, :interval, @interval)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:reload, state) do
    reload(state)
    schedule(state)
    {:noreply, state}
  end

  @doc false
  def reload(%{fetch: fetch, get_settings: get_settings} = state) do
    current = get_settings.()

    with {:ok, latest} <- fetch_latest(fetch),
         [_ | _] = changed <- changed_keys(current, latest) do
      if Enum.any?(changed, &boot?(current, latest, &1)) do
        Logger.info("Boot settings changed; they apply on the next restart",
          keys: Enum.join(changed, ",")
        )

        :restart_required
      else
        apply_live(current, latest, changed, state)
      end
    else
      [] -> :unchanged
      {:error, _reason} -> :error
    end
  end

  defp fetch_latest(fetch) do
    {:ok, fetch.()}
  rescue
    exception ->
      Logger.warning("Could not read App Configuration", reason: Exception.message(exception))
      {:error, exception}
  end

  defp changed_keys(current, latest) do
    Map.keys(current)
    |> Enum.concat(Map.keys(latest))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(current, &1) == Map.get(latest, &1)))
    |> Enum.sort()
  end

  defp boot?(current, latest, key) do
    Enum.any?([Map.get(current, key), Map.get(latest, key)], &match?(%{mode: :boot}, &1))
  end

  defp apply_live(current, latest, changed, %{read_config: read_config, put_settings: put_settings}) do
    old_config = read_config.()
    put_settings.(latest)
    new_config = read_config.()

    for {app, entries} <- new_config,
        {key, value} <- entries,
        get_in(old_config, [app, key]) != value do
      Application.put_env(app, key, value)
    end

    Logger.info("Applied live settings", keys: Enum.join(changed, ","))
    :applied
  rescue
    exception ->
      put_settings.(current)

      Logger.error("Rejected live settings; keeping the current ones",
        keys: Enum.join(changed, ","),
        reason: Exception.message(exception)
      )

      :rejected
  end

  defp read_runtime_config do
    path =
      Path.join([
        System.fetch_env!("RELEASE_ROOT"),
        "releases",
        System.fetch_env!("RELEASE_VSN"),
        "runtime.exs"
      ])

    Config.Reader.read!(path, env: :prod, target: :host)
  end

  defp schedule(%{interval: interval}), do: Process.send_after(self(), :reload, interval)
end
