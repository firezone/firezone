defmodule Portal.OSReleases do
  @moduledoc """
  Answers whether a device runs a current, supported operating system release.

  The releases live in the `os_releases` table, refreshed hourly by
  `Portal.OSReleases.Sync`, and are mirrored into an ETS table on every node so
  a posture evaluation never touches the database. Each node reloads the mirror
  on a timer; the node that ran the sync reloads it at once.
  """

  use GenServer

  alias __MODULE__.Database
  alias Portal.{Defender, Intune, Iru, OSRelease, Santa, SentinelOne}
  alias Portal.Policies.Postures

  @table __MODULE__.ETS
  @reload_every :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # `reload_every: false` leaves the mirror empty and untouched, which the test
  # environment needs: this process has no database sandbox to read through.
  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    interval =
      case Keyword.get(opts, :reload_every, Portal.Config.get_env(:portal, __MODULE__, [])[:reload_every]) do
        nil -> @reload_every
        interval -> interval
      end

    if interval do
      send(self(), :reload)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:reload, %{interval: false} = state), do: {:noreply, state}

  def handle_info(:reload, state) do
    refresh()
    Process.send_after(self(), :reload, state.interval)
    {:noreply, state}
  end

  @doc "Replaces one operating system's release lines with a freshly fetched set."
  @spec replace(OSRelease.os(), [map()]) :: {non_neg_integer(), nil}
  def replace(os, rows), do: Database.replace(os, rows)

  @doc "Asks the mirror on this node to reload from the database now."
  @spec reload() :: :ok
  def reload do
    send(__MODULE__, :reload)
    :ok
  end

  @doc "Reloads the ETS mirror from the database, in the caller's process."
  @spec refresh(:ets.table()) :: :ok
  def refresh(table \\ @table) do
    rows = for release <- Database.list(), do: {{release.os, release.line}, release}
    :ets.delete_all_objects(table)
    :ets.insert(table, rows)
    :ok
  end

  @doc """
  Whether a provider row describes a device on the newest release of a
  supported line. `nil` when the row carries no OS version this can judge.
  """
  @spec row_up_to_date?(struct(), :ets.table()) :: boolean() | nil
  def row_up_to_date?(row, table \\ @table) when is_struct(row) do
    case os_and_version(row) do
      {os, version} when is_binary(version) -> up_to_date?(os, version, table)
      _unknown -> nil
    end
  end

  @spec up_to_date?(OSRelease.os(), String.t(), :ets.table()) :: boolean() | nil
  def up_to_date?(os, version, table \\ @table) do
    segments = Postures.parse_version(version)

    with line when is_binary(line) <- line_for(os, segments),
         [{_key, release}] <- :ets.lookup(table, {os, line}) do
      release.supported and Postures.compare_versions(segments, Postures.parse_version(release.latest_version)) != :lt
    else
      [] -> false
      nil -> nil
    end
  end

  @doc "The release line a version belongs to, in the form the feeds are stored under."
  @spec line_for(OSRelease.os(), [non_neg_integer()]) :: String.t() | nil
  def line_for(:windows, [10, 0, build | _rest]), do: "10.0.#{build}"
  def line_for(:linux, [major, minor | _rest]), do: "#{major}.#{minor}"
  def line_for(os, [major | _rest]) when os in [:macos, :ios, :android], do: Integer.to_string(major)
  def line_for(_os, _segments), do: nil

  defp os_and_version(%Intune.Device{operating_system: os, os_version: version}), do: {apple_or_other(os), version}
  defp os_and_version(%Iru.Device{os_name: os, os_version: version}), do: {apple_or_other(os), version}
  defp os_and_version(%Defender.Device{os_platform: "macOS", version: version}), do: {:macos, version}
  defp os_and_version(%Santa.Device{os_version: version}), do: {:macos, version}
  defp os_and_version(%SentinelOne.Device{os_type: "macos", os_revision: version}), do: {:macos, version}

  # SentinelOne reports a Windows build only sometimes; a marketing name such as
  # 24H2 cannot be placed on a line.
  defp os_and_version(%SentinelOne.Device{os_type: "windows", os_revision: "10.0." <> _rest = version}),
    do: {:windows, version}

  defp os_and_version(_row), do: nil

  defp apple_or_other(nil), do: nil

  defp apple_or_other(name) do
    case String.downcase(name) do
      "windows" -> :windows
      "macos" -> :macos
      "ios" -> :ios
      "ipados" -> :ios
      "android" -> :android
      _other -> nil
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{OSRelease, Safe}

    def list do
      OSRelease
      |> Safe.unscoped()
      |> Safe.all()
    end

    # Replaces one operating system's lines with the fetched set; a line that
    # left the feed is gone, which the lookup reads as unsupported.
    def replace(os, rows) do
      lines = Enum.map(rows, & &1.line)

      from(r in OSRelease, where: r.os == ^os and r.line not in ^lines)
      |> Safe.unscoped()
      |> Safe.delete_all()

      Safe.unscoped()
      |> Safe.insert_all(OSRelease, rows,
        on_conflict: {:replace, ~w[latest_version supported fetched_at updated_at]a},
        conflict_target: [:os, :line]
      )
    end
  end
end
