defmodule Portal.SlugRegistryHelpers do
  @moduledoc """
  Points the slug registry at a stubbed Azure Table for one test.
  """
  import Plug.Conn

  @table_url "https://registry.example.test"

  def use_azure_registry(region \\ :us) do
    Portal.Config.put_env_override(:data_residency_region, region)
    Portal.Config.put_env_override(:slug_registry_table_url, @table_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "registry-token", "expires_on" => "4102444800"})
    end)

    :ok
  end

  @doc "Stubs the table with `handler.(conn)`; a stub that returns `:default` answers like an empty table."
  def stub_registry(handler) do
    Req.Test.stub(Portal.SlugRegistry.AzureTable, fn conn ->
      conn = fetch_query_params(conn)

      case handler.(conn) do
        :default -> empty_table(conn)
        conn -> conn
      end
    end)
  end

  def empty_table(%{method: "POST", request_path: "/slugs"} = conn), do: send_resp(conn, 204, "")
  def empty_table(%{method: "GET", request_path: "/slugs()"} = conn), do: Req.Test.json(conn, %{"value" => []})
  def empty_table(%{method: "GET"} = conn), do: send_resp(conn, 404, "")
  def empty_table(%{method: "DELETE"} = conn), do: send_resp(conn, 404, "")

  def entity(slug, account_id, region) do
    %{"PartitionKey" => "slug", "RowKey" => slug, "AccountId" => account_id, "Region" => region}
  end

  def row_key(conn) do
    case Regex.run(~r/RowKey='([^']*)'/, conn.request_path) do
      [_, slug] -> URI.decode(slug)
      nil -> nil
    end
  end

  def json_body(conn) do
    {:ok, body, _conn} = read_body(conn)
    Jason.decode!(body)
  end
end
