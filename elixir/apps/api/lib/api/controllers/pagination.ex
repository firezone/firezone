defmodule API.Pagination do
  alias LoggerJSON.Formatter.Metadata
  alias Domain.Repo.Paginator.Metadata

  def params_to_list_opts(params) do
    params_to_list_opts([], params)
  end

  def params_to_list_opts(list_opts, params) do
    case params_to_page(params) do
      {:ok, value} -> {:ok, Keyword.merge(list_opts, page: value)}
      other -> other
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
    case Integer.parse(limit) do
      {value, ""} -> {:ok, [cursor: cursor, limit: value]}
      _other -> {:error, :bad_request}
    end
  end

  defp params_to_page(%{"limit" => limit}) do
    case Integer.parse(limit) do
      {value, ""} -> {:ok, [limit: value]}
      _other -> {:error, :bad_request}
    end
  end

  defp params_to_page(%{"page_cursor" => cursor}) do
    {:ok, [cursor: cursor]}
  end

  defp params_to_page(_params) do
    {:ok, []}
  end
end
