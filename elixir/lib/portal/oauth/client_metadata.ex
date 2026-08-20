defmodule Portal.OAuth.ClientMetadata do
  @moduledoc """
  Resolves an OAuth client id into the metadata document it names.

  MCP clients identify themselves with an HTTPS URL that serves a JSON document
  describing them, so there is no registration step and no client secret. The
  document is fetched on demand, checked, and cached.

  The URL comes from whoever started the authorization request, so the fetch is
  treated as hostile: `Portal.Req.SSRFProtection` is already attached to every
  request and refuses private and reserved addresses, and the caps here bound
  how much time and memory one lookup can cost.
  """

  alias Portal.OAuthClient
  alias __MODULE__.Database

  require Logger

  @receive_timeout :timer.seconds(5)
  @max_body_bytes 64 * 1024
  @min_cache :timer.minutes(5)
  @default_cache :timer.hours(1)
  @max_cache :timer.hours(24)

  @doc """
  Returns the client for `client_id`, fetching and caching the document when
  the cached copy is missing or stale.
  """
  def fetch(client_id) do
    with :ok <- validate_client_id(client_id) do
      case Database.fetch_fresh_client(client_id) do
        {:ok, client} -> {:ok, client}
        :error -> fetch_and_cache(client_id)
      end
    end
  end

  @doc """
  Checks a redirect URI from an authorization request against the document.

  Compared exactly, with no prefix or wildcard matching, because a loose match
  here is what turns an open redirect into a stolen authorization code.
  """
  def validate_redirect_uri(%OAuthClient{} = client, redirect_uri) do
    if redirect_uri in client.redirect_uris do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp validate_client_id(client_id) when is_binary(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path}
      when is_binary(host) and is_binary(path) and path != "" and path != "/" ->
        :ok

      _other ->
        {:error, :invalid_client_id}
    end
  end

  defp validate_client_id(_client_id), do: {:error, :invalid_client_id}

  defp fetch_and_cache(client_id) do
    with {:ok, response} <- get(client_id),
         {:ok, document} <- decode(response.body),
         :ok <- validate_document(document, client_id) do
      upsert(document, client_id, cache_until(response))
    else
      {:error, reason} = error ->
        Logger.info("OAuth client metadata fetch failed",
          client_id: client_id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp get(client_id) do
    Req.get(client_id,
      headers: [{"accept", "application/json"}],
      receive_timeout: @receive_timeout,
      max_retries: 0,
      redirect: false,
      into: &collect/2
    )
    |> case do
      {:ok, %Req.Response{status: 200} = response} -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Halting mid-body keeps an oversized or endless document from being read into
  # memory, which a plain byte check after the fact would not.
  defp collect({:data, data}, {request, response}) do
    body = (response.body || "") <> data

    if byte_size(body) > @max_body_bytes do
      {:halt, {request, %{response | body: :too_large}}}
    else
      {:cont, {request, %{response | body: body}}}
    end
  end

  defp decode(:too_large), do: {:error, :document_too_large}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _other -> {:error, :invalid_document}
    end
  end

  defp decode(_body), do: {:error, :invalid_document}

  # The document has to name itself. Without this check any URL could serve a
  # document claiming to be some other, more trusted client.
  defp validate_document(document, client_id) do
    with %{"client_id" => ^client_id, "client_name" => name, "redirect_uris" => uris}
         when is_binary(name) and is_list(uris) <- document,
         true <- uris != [] and Enum.all?(uris, &is_binary/1) do
      :ok
    else
      _other -> {:error, :invalid_document}
    end
  end

  defp upsert(document, client_id, metadata_expires_at) do
    %OAuthClient{}
    |> Ecto.Changeset.cast(
      %{
        client_id: client_id,
        client_name: document["client_name"],
        client_uri: document["client_uri"],
        logo_uri: document["logo_uri"],
        redirect_uris: document["redirect_uris"],
        metadata_expires_at: metadata_expires_at
      },
      ~w[client_id client_name client_uri logo_uri redirect_uris metadata_expires_at]a
    )
    |> Database.upsert_client()
  end

  defp cache_until(%Req.Response{} = response) do
    milliseconds =
      response
      |> Req.Response.get_header("cache-control")
      |> List.first()
      |> max_age()
      |> case do
        nil -> @default_cache
        seconds -> seconds |> :timer.seconds() |> min(@max_cache) |> max(@min_cache)
      end

    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  defp max_age(nil), do: nil

  defp max_age(cache_control) do
    case Regex.run(~r/max-age=(\d+)/i, cache_control) do
      [_match, seconds] -> String.to_integer(seconds)
      nil -> nil
    end
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query

    alias Portal.OAuthClient
    alias Portal.Safe

    def fetch_fresh_client(client_id) do
      now = DateTime.utc_now()

      from(clients in OAuthClient,
        where: clients.client_id == ^client_id,
        where: clients.metadata_expires_at > ^now
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> :error
        client -> {:ok, client}
      end
    end

    # `returning: true` matters: the id is generated client side, so without it
    # a conflicting insert would hand back the id it just made up rather than
    # the id of the row that grants already point at.
    def upsert_client(changeset) do
      Safe.insert(Portal.Repo, changeset,
        on_conflict:
          {:replace,
           ~w[client_name client_uri logo_uri redirect_uris metadata_expires_at updated_at]a},
        conflict_target: [:client_id],
        returning: true
      )
    end
  end
end
