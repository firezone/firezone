defmodule Portal.AvatarStorageHelpers do
  @moduledoc """
  An in-memory blob container for `Portal.Avatars.Storage`.
  """
  import Plug.Conn

  @container_url "https://avatars.example.com/avatars"

  def jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0, "jpeg photo">>
  def png, do: <<0x89, "PNG\r\n", 0x1A, "\n", "png photo">>

  @doc """
  Configures the container and returns an Agent that holds its blobs by name.
  """
  def stub_avatar_storage do
    Portal.Config.put_env_override(:avatars_container_url, @container_url)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{"access_token" => "storage-token", "expires_on" => "4102444800"})
    end)

    {:ok, store} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(Portal.Avatars.Storage, fn conn ->
      ["Bearer storage-token"] = get_req_header(conn, "authorization")
      name = String.replace_prefix(conn.request_path, "/avatars/", "")

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = read_body(conn)
          [type] = get_req_header(conn, "x-ms-blob-content-type")
          Agent.update(store, &Map.put(&1, name, {body, type, DateTime.utc_now()}))
          send_resp(conn, 201, "")

        "DELETE" ->
          Agent.update(store, &Map.delete(&1, name))
          send_resp(conn, 202, "")

        "GET" when conn.request_path == "/avatars" ->
          prefix = fetch_query_params(conn).query_params["prefix"]
          blobs =
            for {name, {_body, _type, modified}} <- Agent.get(store, & &1),
                String.starts_with?(name, prefix),
                into: "" do
              modified = Calendar.strftime(modified, "%a, %d %b %Y %H:%M:%S GMT")
              "<Blob><Name>#{name}</Name><Properties><Last-Modified>#{modified}</Last-Modified></Properties></Blob>"
            end

          send_resp(conn, 200, "<EnumerationResults><Blobs>#{blobs}</Blobs><NextMarker /></EnumerationResults>")

        "GET" ->
          case Agent.get(store, &Map.fetch(&1, name)) do
            {:ok, {body, _type, _modified}} -> send_resp(conn, 200, body)
            :error -> send_resp(conn, 404, "")
          end
      end
    end)

    store
  end

  @doc """
  The stored blobs as `%{name => {body, content_type}}`.
  """
  def blobs(store), do: Agent.get(store, &Map.new(&1, fn {name, {body, type, _modified}} -> {name, {body, type}} end))

  @doc """
  The blob of a photo version, the identity's current one unless given.
  """
  def blob_name(identity, etag \\ nil) do
    "#{identity.account_id}/#{identity.id}/#{Portal.Avatars.version(etag || identity.avatar_etag)}"
  end

  @doc """
  Seeds a blob. It is a day old unless `:modified_at` says otherwise, so prune
  treats it as settled.
  """
  def put_blob(store, name, body, opts \\ []) do
    type = Keyword.get(opts, :type, "image/jpeg")
    modified = Keyword.get_lazy(opts, :modified_at, fn -> DateTime.add(DateTime.utc_now(), -1, :day) end)
    Agent.update(store, &Map.put(&1, name, {body, type, modified}))
  end
end
