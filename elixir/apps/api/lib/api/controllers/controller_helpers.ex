defmodule API.ControllerHelpers do
  def params_to_list_opts(params) do
    [
      page: params_to_page(params)
    ]
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
