defmodule API.Pagination do
  alias LoggerJSON.Formatter.Metadata
  alias Domain.Repo.Paginator.Metadata

  def params_to_list_opts(params) do
    [
      page: params_to_page(params)
    ]
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
    [cursor: cursor, limit: String.to_integer(limit)]
  end

  defp params_to_page(%{"limit" => limit}) do
    [limit: String.to_integer(limit)]
  end

  defp params_to_page(%{"page_cursor" => cursor}) do
    [cursor: cursor]
  end

  defp params_to_page(_params) do
    []
  end
end
