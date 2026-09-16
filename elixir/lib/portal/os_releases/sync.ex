defmodule Portal.OSReleases.Sync do
  @moduledoc """
  Daily Oban worker that refreshes `os_releases` from the vendors' feeds.

  Apple and the Linux kernel publish machine-readable feeds of the releases they
  still support. Microsoft and Google do not, so Windows, Windows Server and
  Android come from endoflife.date, which tracks their release health pages. A
  feed that fails leaves that operating system's rows as they were.

  Apple serves its feed from a certificate chain that ends at Apple's own root,
  which public bundles do not carry, so that request trusts the copy of Apple
  Root CA shipped in `priv/certs`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Portal.OSReleases

  @apple_url "https://gdmf.apple.com/v2/pmv"
  @kernel_url "https://www.kernel.org/releases.json"
  @windows_urls ["https://endoflife.date/api/windows.json", "https://endoflife.date/api/windows-server.json"]
  @android_url "https://endoflife.date/api/android.json"

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {os, fetch} <- [
          macos: &fetch_apple(&1, "macOS", "Mac"),
          ios: &fetch_apple(&1, "iOS", "iP"),
          linux: &fetch_kernel/1,
          windows: &fetch_windows/1,
          android: &fetch_android/1
        ] do
      case fetch.(now) do
        {:ok, rows} when rows != [] ->
          OSReleases.replace(os, Enum.map(rows, &Map.put(&1, :os, os)))

        {:ok, []} ->
          Logger.warning("OS release feed returned no lines", os: os)

        {:error, reason} ->
          Logger.warning("Can't fetch OS releases", os: os, reason: inspect(reason))
      end
    end

    OSReleases.reload()
  end

  # Apple lists the versions it still signs. Watches share the iOS asset set, so
  # a version counts only if a device of the wanted family can run it.
  defp fetch_apple(now, set, device_prefix) do
    cacertfile = Application.app_dir(:portal, "priv/certs/apple_root_ca.pem")

    with {:ok, %{"PublicAssetSets" => sets}} <-
           get(@apple_url, connect_options: [transport_opts: [cacertfile: cacertfile]]) do
      rows =
        sets
        |> Map.get(set, [])
        |> Enum.filter(fn asset -> Enum.any?(asset["SupportedDevices"] || [], &String.starts_with?(&1, device_prefix)) end)
        |> Enum.map(& &1["ProductVersion"])
        |> newest_per_line(fn segments -> OSReleases.line_for(major_os(set), segments) end)
        |> Enum.map(fn {line, latest} -> row(line, latest, true, now) end)

      {:ok, rows}
    end
  end

  defp major_os("macOS"), do: :macos
  defp major_os(_ios), do: :ios

  defp fetch_kernel(now) do
    with {:ok, %{"releases" => releases}} <- get(@kernel_url) do
      rows =
        for %{"moniker" => moniker, "version" => version, "iseol" => eol?} <- releases,
            moniker in ["stable", "longterm"],
            line = OSReleases.line_for(:linux, Portal.Policies.Postures.parse_version(version)),
            is_binary(line),
            do: row(line, version, not eol?, now)

      {:ok, rows}
    end
  end

  # Windows editions share a build, so the lines of every cycle on that build
  # merge: supported while any edition is, at the newest patch either reports.
  defp fetch_windows(now) do
    with {:ok, cycles} when is_list(cycles) <- get_all(@windows_urls) do
      rows =
        cycles
        |> Enum.flat_map(&windows_line(&1, now))
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.map(fn {line, entries} ->
          latest = entries |> Enum.map(&elem(&1, 1)) |> Enum.max_by(&Portal.Policies.Postures.parse_version/1, &version_gte?/2)
          row(line, latest, Enum.any?(entries, &elem(&1, 2)), now)
        end)

      {:ok, rows}
    end
  end

  defp windows_line(cycle, now) do
    segments = Portal.Policies.Postures.parse_version(cycle["latest"] || "")

    case OSReleases.line_for(:windows, segments) do
      nil -> []
      line -> [{line, cycle["latest"], supported?(cycle["eol"], now)}]
    end
  end

  defp fetch_android(now) do
    with {:ok, cycles} when is_list(cycles) <- get(@android_url) do
      rows =
        for %{"cycle" => cycle} = entry <- cycles,
            line = OSReleases.line_for(:android, Portal.Policies.Postures.parse_version(cycle)),
            is_binary(line),
            do: row(line, cycle, supported?(entry["eol"], now), now)

      {:ok, rows}
    end
  end

  defp newest_per_line(versions, line_fun) do
    versions
    |> Enum.filter(&is_binary/1)
    |> Enum.group_by(fn version -> line_fun.(Portal.Policies.Postures.parse_version(version)) end)
    |> Enum.reject(fn {line, _versions} -> is_nil(line) end)
    |> Enum.map(fn {line, versions} ->
      {line, Enum.max_by(versions, &Portal.Policies.Postures.parse_version/1, &version_gte?/2)}
    end)
  end

  defp version_gte?(left, right), do: Portal.Policies.Postures.compare_versions(left, right) != :lt

  # endoflife.date writes `false` for a cycle with no end date yet.
  defp supported?(false, _now), do: true
  defp supported?(true, _now), do: false

  defp supported?(date, now) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, eol} -> Date.compare(eol, DateTime.to_date(now)) == :gt
      _error -> false
    end
  end

  defp supported?(_other, _now), do: false

  defp row(line, latest, supported?, now) do
    %{line: line, latest_version: latest, supported: supported?, fetched_at: now, inserted_at: now, updated_at: now}
  end

  defp get_all(urls) do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
      case get(url) do
        {:ok, list} when is_list(list) -> {:cont, {:ok, acc ++ list}}
        {:ok, _other} -> {:halt, {:error, {:unexpected_body, url}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp get(url, extra_opts \\ []) do
    req_opts =
      Portal.Config.fetch_env!(:portal, __MODULE__)
      |> Keyword.get(:req_opts, [])
      |> Keyword.merge(extra_opts)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) -> {:ok, body}
      {:ok, response} -> {:error, {response.status, response.body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
