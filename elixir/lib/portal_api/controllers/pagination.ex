defmodule PortalAPI.Pagination do
  alias Portal.Repo.Paginator
  alias Portal.Repo.Paginator.Metadata

  @max_limit Paginator.max_limit()

  def limit_schema do
    %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: @max_limit}
  end

  @spec params_to_list_opts(map()) :: {:ok, keyword()} | {:error, :bad_request, reason: String.t()}
  def params_to_list_opts(params) do
    with {:ok, page} <- params_to_page(params) do
      {:ok, [page: page]}
    end
  end

  def metadata(%Metadata{} = metadata) do
    %{
      count: metadata.count,
      limit: metadata.limit,
      next_page: metadata.next_page_cursor,
      prev_page: metadata.previous_page_cursor
    }
  end

  defp params_to_page(%{"limit" => limit, "page_cursor" => cursor}) do
    with {:ok, limit} <- parse_limit(limit),
         :ok <- validate_cursor_size(cursor) do
      {:ok, [cursor: cursor, limit: limit]}
    end
  end

  defp params_to_page(%{"limit" => limit}) do
    with {:ok, limit} <- parse_limit(limit) do
      {:ok, [limit: limit]}
    end
  end

  defp params_to_page(%{"page_cursor" => cursor}) do
    with :ok <- validate_cursor_size(cursor) do
      {:ok, [cursor: cursor]}
    end
  end

  defp params_to_page(_params) do
    {:ok, []}
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} when int >= 1 and int <= @max_limit -> {:ok, int}
      {_int, ""} -> {:error, :bad_request, reason: "limit must be between 1 and #{@max_limit}"}
      _ -> {:error, :bad_request, reason: "limit must be an integer"}
    end
  end

  defp validate_cursor_size(cursor) when is_binary(cursor) do
    if byte_size(cursor) <= Paginator.max_encoded_cursor_bytes() do
      :ok
    else
      invalid_cursor_size()
    end
  end

  defp validate_cursor_size(_cursor), do: invalid_cursor_size()

  defp invalid_cursor_size do
    {:error,
     :bad_request,
     reason: "page_cursor must be at most #{Paginator.max_encoded_cursor_bytes()} bytes"}
  end
end
