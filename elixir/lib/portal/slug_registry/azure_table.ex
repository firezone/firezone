defmodule Portal.SlugRegistry.AzureTable do
  @moduledoc """
  The shared slug registry of Firezone Cloud: one Azure Table with the slug as
  the row key. Inserting a row that exists fails with 409, which is the whole
  uniqueness guarantee. Requests carry the portal's managed identity token.
  """
  @behaviour Portal.SlugRegistry

  require Logger

  @api_version "2020-12-06"
  @partition "slug"
  @scope "https://storage.azure.com/"
  @table "slugs"

  @impl true
  def claim(slug, account_id, region) do
    entity = %{
      "PartitionKey" => @partition,
      "RowKey" => slug,
      "AccountId" => account_id,
      "Region" => Atom.to_string(region),
      "InsertedAt" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case request(:post, "/#{@table}", json: entity, headers: [{"prefer", "return-no-content"}]) do
      {:ok, %{status: status}} when status in [201, 204] -> :ok
      {:ok, %{status: 409}} -> claimed_by_same_account(slug, account_id)
      other -> unavailable(:claim, slug, other)
    end
  end

  @impl true
  def release(slug, account_id) do
    case lookup(slug) do
      {:ok, %{account_id: ^account_id}} -> delete(slug)
      {:ok, _other_account} -> :ok
      :not_found -> :ok
      {:error, :unavailable} = error -> error
    end
  end

  @impl true
  def lookup(slug) do
    case request(:get, entity_path(slug), []) do
      {:ok, %{status: 200, body: body}} -> {:ok, entry(body)}
      {:ok, %{status: 404}} -> :not_found
      other -> unavailable(:lookup, slug, other)
    end
  end

  @impl true
  def transfer(account_id, region) do
    with {:ok, entries} <- query("AccountId eq '#{account_id}'") do
      Enum.reduce_while(entries, {:ok, 0}, &move(&1, Atom.to_string(region), &2))
    end
  end

  defp move(entry, region, {:ok, moved}) do
    case merge(entry.slug, %{"Region" => region}) do
      :ok -> {:cont, {:ok, moved + 1}}
      {:error, :unavailable} = error -> {:halt, error}
    end
  end

  @impl true
  def list_region(region), do: query("Region eq '#{region}'")

  defp claimed_by_same_account(slug, account_id) do
    case lookup(slug) do
      {:ok, %{account_id: ^account_id}} -> :ok
      {:ok, _other_account} -> {:error, :taken}
      :not_found -> {:error, :taken}
      {:error, :unavailable} = error -> error
    end
  end

  defp delete(slug) do
    case request(:delete, entity_path(slug), headers: [{"if-match", "*"}]) do
      {:ok, %{status: status}} when status in [204, 404] -> :ok
      other -> unavailable(:release, slug, other)
    end
  end

  # Azure Tables merge with the MERGE verb; the header form lets any HTTP
  # client send it.
  defp merge(slug, changes) do
    case request(:post, entity_path(slug),
           json: changes,
           headers: [{"if-match", "*"}, {"x-http-method", "MERGE"}]
         ) do
      {:ok, %{status: 204}} -> :ok
      other -> unavailable(:transfer, slug, other)
    end
  end

  defp query(filter), do: query(filter, [], nil)

  defp query(filter, acc, continuation) do
    params = [{"$filter", filter}, {"$select", "RowKey,AccountId,Region,InsertedAt"}] ++ (continuation || [])

    case request(:get, "/#{@table}()", params: params) do
      {:ok, %{status: 200, body: %{"value" => rows}, headers: headers}} ->
        acc = acc ++ Enum.map(rows, &entry/1)

        case next_page(headers) do
          nil -> {:ok, acc}
          next -> query(filter, acc, next)
        end

      other ->
        unavailable(:query, filter, other)
    end
  end

  defp next_page(headers) do
    with [partition] <- Map.get(headers, "x-ms-continuation-nextpartitionkey"),
         [row] <- Map.get(headers, "x-ms-continuation-nextrowkey") do
      [{"NextPartitionKey", partition}, {"NextRowKey", row}]
    else
      _ -> nil
    end
  end

  defp entry(body) do
    %{
      slug: body["RowKey"],
      account_id: body["AccountId"],
      region: body["Region"],
      inserted_at: body["InsertedAt"]
    }
  end

  defp entity_path(slug) do
    "/#{@table}(PartitionKey='#{@partition}',RowKey='#{URI.encode(slug, &URI.char_unreserved?/1)}')"
  end

  defp request(method, path, opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    with {:ok, token} <- token() do
      [
        method: method,
        url: table_url() <> path,
        headers: [
          {"authorization", "Bearer " <> token},
          {"x-ms-version", @api_version},
          {"x-ms-date", Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")},
          {"accept", "application/json;odata=nometadata"},
          {"dataserviceversion", "3.0"}
        ]
      ]
      |> Keyword.merge(config[:req_opts] || [])
      |> Keyword.merge(opts, fn
        :headers, base, extra -> base ++ extra
        _key, _base, extra -> extra
      end)
      |> Req.new()
      |> Req.request()
    end
  end

  defp token do
    {:ok, Portal.Azure.ManagedIdentity.access_token!(@scope)}
  rescue
    exception -> {:error, exception}
  end

  defp table_url do
    Portal.Config.fetch_env!(:portal, :slug_registry_table_url) |> String.trim_trailing("/")
  end

  defp unavailable(operation, key, result) do
    Logger.error("Slug registry request failed",
      operation: operation,
      key: key,
      result: inspect(result, limit: 200)
    )

    {:error, :unavailable}
  end
end
