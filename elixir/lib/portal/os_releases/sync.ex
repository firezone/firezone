defmodule Portal.OSReleases.Sync do
  @moduledoc """
  Daily Oban worker that refreshes `os_releases` from the vendors.

  Apple and the Linux kernel publish anonymous feeds of the releases they still
  support. Microsoft publishes none, so Windows comes from the Windows Update
  for Business deployment service catalog on Microsoft Graph, read as a
  single-tenant application in the Firezone tenant. Android needs no feed: it
  is judged by the device's security patch level.

  A source that fails is reported with everything the response said and leaves
  that operating system's rows as they were. Apple serves its feed from a
  certificate chain that ends at Apple's own root, which public bundles do not
  carry, so that request trusts the copy of Apple Root CA shipped in
  `priv/certs`.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  require Logger

  alias Portal.Microsoft.Graph.APIClient
  alias Portal.OSReleases
  alias Portal.Policies.Postures

  @apple_url "https://gdmf.apple.com/v2/pmv"
  @kernel_url "https://www.kernel.org/releases.json"

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for {os, fetch} <- [
          macos: &fetch_apple(&1, "macOS", "Mac"),
          ios: &fetch_apple(&1, "iOS", "iP"),
          linux: &fetch_kernel/1,
          windows: &fetch_windows/1
        ] do
      case fetch.(now) do
        {:ok, rows} when rows != [] ->
          OSReleases.replace(os, Enum.map(rows, &Map.put(&1, :os, os)))

        {:ok, []} ->
          Logger.error("OS release source for #{os} returned no release lines", os: os)

        :skip ->
          Logger.info("OS release source for #{os} is not configured", os: os)

        {:error, details} ->
          summary = Enum.map_join(details, " ", fn {key, value} -> "#{key}=#{value}" end)
          Logger.error("Can't fetch OS releases for #{os}: #{summary}", [os: os] ++ details)
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
            line = OSReleases.line_for(:linux, Postures.parse_version(version)),
            is_binary(line),
            do: row(line, version, not eol?, now)

      {:ok, rows}
    end
  end

  # Every product in the catalog is one Microsoft still services, and every
  # revision is a build it shipped, so a line is current at its newest revision.
  defp fetch_windows(now) do
    tenant_id = Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.get(:windows_updates_tenant_id)
    client_id = APIClient.client_id(:windows_updates)

    if blank?(tenant_id) or blank?(client_id) do
      :skip
    else
      with {:ok, token} <- windows_updates_token(tenant_id),
           {:ok, products} <- windows_update_products(token) do
        rows =
          products
          |> Enum.flat_map(fn product -> Enum.map(product["revisions"] || [], &revision_version/1) end)
          |> newest_per_line(&OSReleases.line_for(:windows, &1))
          |> Enum.map(fn {line, latest} -> row(line, latest, true, now) end)

        {:ok, rows}
      end
    end
  end

  defp windows_updates_token(tenant_id) do
    case APIClient.get_access_token(:windows_updates, tenant_id) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, [step: :token, tenant_id: tenant_id, status: status, body: inspect(body)]}

      {:error, reason} ->
        {:error, [step: :token, tenant_id: tenant_id, reason: inspect(reason)]}
    end
  end

  defp windows_update_products(token) do
    token
    |> APIClient.stream_windows_update_products()
    |> Enum.reduce_while({:ok, []}, fn
      {:error, %Req.Response{status: status, body: body}}, _acc ->
        {:halt, {:error, [step: :products, status: status, body: inspect(body)]}}

      {:error, reason}, _acc ->
        {:halt, {:error, [step: :products, reason: inspect(reason)]}}

      page, {:ok, acc} when is_list(page) ->
        {:cont, {:ok, acc ++ page}}
    end)
  end

  defp revision_version(%{"osBuild" => %{} = build}) do
    ~w[majorVersion minorVersion buildNumber updateBuildRevision]
    |> Enum.map(&build[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
  end

  defp revision_version(%{"version" => version}) when is_binary(version), do: version
  defp revision_version(_revision), do: ""

  defp newest_per_line(versions, line_fun) do
    versions
    |> Enum.filter(&is_binary/1)
    |> Enum.group_by(fn version -> line_fun.(Postures.parse_version(version)) end)
    |> Enum.reject(fn {line, _versions} -> is_nil(line) end)
    |> Enum.map(fn {line, versions} -> {line, Enum.max_by(versions, &Postures.parse_version/1, &version_gte?/2)} end)
  end

  defp version_gte?(left, right), do: Postures.compare_versions(left, right) != :lt

  defp row(line, latest, supported?, now) do
    %{line: line, latest_version: latest, supported: supported?, fetched_at: now, inserted_at: now, updated_at: now}
  end

  defp blank?(value), do: value in [nil, ""]

  defp get(url, extra_opts \\ []) do
    req_opts =
      Portal.Config.fetch_env!(:portal, __MODULE__)
      |> Keyword.get(:req_opts, [])
      |> Keyword.merge(extra_opts)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) or is_list(body) -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, [url: url, status: status, body: inspect(body)]}
      {:error, reason} -> {:error, [url: url, reason: inspect(reason)]}
    end
  end
end
