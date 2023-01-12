defmodule Firezone.DocusaurusWriter do
  @keep_req_headers ["authorization"]
  @keep_resp_headers ["content-type", "location"]

  @authorization_ref "See [\"Authorization\"](../authorization) section"

  def write(conns, path) do
    File.mkdir_p!(path)
    routes = Phoenix.Router.routes(List.first(conns).private.phoenix_router)

    conns
    |> Enum.group_by(& &1.private.phoenix_controller)
    |> Enum.map(fn {controller, conns} ->
      {module_doc, module_assigns, function_docs} = fetch_module_docs!(controller)

      title =
        Keyword.get_lazy(module_assigns, :title, fn ->
          controller
          |> to_string()
          |> String.split(".")
          |> List.last()
          |> String.replace_trailing("Controller", "")
        end)

      path = Path.join(path, "#{String.downcase(title)}.mdx")
      file = File.open!(path, [:write, :utf8])

      w!(file, "---")
      w!(file, docusaurus_header(module_assigns))
      w!(file, "---")
      w!(file, "\n")
      w!(file, module_doc)
      w!(file, "## API Documentation")

      conns
      |> Enum.group_by(& &1.private.phoenix_action)
      # We order actions nicely
      |> Enum.sort_by(fn
        {:index, _} -> 1
        {:show, _} -> 3
        {:create, _} -> 2
        {:update, _} -> 4
        {:delete, _} -> 5
        {_other, _} -> 1000
      end)
      |> Enum.map(fn {action, conns} ->
        {path, verb} = fetch_route!(routes, controller, action)
        {function_doc, function_assigns} = get_function_docs(function_docs, action)

        title = function_assigns[:action] || "#{verb} #{path}"

        w!(file, "### #{title}")
        w!(file, "`#{verb} #{path}`")
        w!(file, "\n")
        w!(file, function_doc)

        uri_params = build_uri_params(path)

        write_examples(file, conns, uri_params)
      end)
    end)
  end

  defp docusaurus_header(assigns) do
    assigns
    |> Enum.map(fn {key, value} ->
      "#{key}: #{value}"
    end)
    |> Enum.join("\n")
  end

  defp fetch_route!(routes, controller, controller_action) do
    %{path: path, verb: verb} =
      Enum.find(routes, fn
        %{plug: ^controller, plug_opts: ^controller_action} -> true
        _other -> false
      end)

    path = String.replace(path, ~r|:([^/]*)|, "{\\1}")
    verb = verb |> to_string() |> String.upcase()

    {path, verb}
  end

  defp fetch_module_docs!(controller) do
    case Code.fetch_docs(controller) do
      {:docs_v1, _, _, _, module_doc, %{api_doc: module_assigns}, function_docs} ->
        {get_doc(module_doc), module_assigns, function_docs}

      {:error, :module_not_found} ->
        raise "No module #{controller}"
    end
  end

  defp get_doc(md) when is_map(md), do: Map.get(md, "en")
  defp get_doc(_md), do: nil

  defp get_function_docs(function_docs, function) do
    function_docs
    |> Enum.find(fn
      {{:function, ^function, _}, _, _, _, _} -> true
      {{:function, _function, _}, _, _, _, _} -> false
    end)
    |> case do
      {_, _, _, :none, %{api_doc: function_assigns}} ->
        {nil, function_assigns}

      {_, _, _, doc, %{api_doc: function_assigns}} ->
        {get_doc(doc), function_assigns}

      {_, _, _, doc, _chunks} ->
        {get_doc(doc), %{}}

      _other ->
        {nil, %{}}
    end
  end

  defp build_uri_params(path) do
    Regex.scan(~r/{([^}]*)}/, path)
    |> Enum.map(fn [_, param] ->
      param
    end)
  end

  defp write_examples(file, conns, uri_params) do
    conns
    |> Enum.sort_by(& &1.status)
    |> Enum.each(fn conn ->
      example_description = conn.assigns.bureaucrat_opts[:example_description] || "Example"
      w!(file, "#### #{example_description}")
      w!(file, "**Request**")

      w_req_uri_params!(file, conn, uri_params)
      w_req_headers!(file, conn)
      w_req_body!(file, conn.body_params)

      w!(file, "**Response**")

      w_resp_headers!(file, conn)
      w_resp_body!(file, conn.resp_body)
    end)
  end

  defp w_req_uri_params!(_file, _conn, []), do: :ok

  defp w_req_uri_params!(file, conn, params) do
    w!(file, "##### URI Parameters")
    w!(file, "| Name | Value | Description |")
    w!(file, "| ---- | ----- | ----------- |")

    Enum.each(params, fn param ->
      w!(file, "| #{param} | #{conn.params[param]} | |")
    end)
  end

  defp w_req_headers!(file, conn) do
    w!(file, "##### Headers")

    w!(file, "| Name | Value | Description |")
    w!(file, "| ---- | ----- | ----------- |")

    for {key, value} <- conn.req_headers, key in @keep_req_headers do
      case {key, value} do
        {"authorization", "bearer " <> _} ->
          w!(file, "| Authorization | Bearer {api_token} | #{@authorization_ref} |")

        {key, value} ->
          w!(file, "| #{camelize_header_key(key)} | #{value} | |")
      end
    end
  end

  defp w_req_body!(_file, params) when params == %{}, do: :ok

  defp w_req_body!(file, params) do
    w!(file, "##### Body")

    w!(file, """
    ```json
    #{Jason.encode!(params, pretty: true)}
    ```
    """)
  end

  defp w_resp_headers!(file, conn) do
    w!(file, "##### Headers")

    w!(file, "| Name | Value |")
    w!(file, "| ---- | ----- |")

    for {key, value} <- conn.resp_headers, key in @keep_resp_headers do
      w!(file, "| #{camelize_header_key(key)} | #{value} |")
    end
  end

  defp w_resp_body!(file, resp_body) do
    w!(file, "##### Body")

    w =
      case Jason.decode(resp_body) do
        {:ok, map} ->
          """
          ```json
          #{Jason.encode!(map, pretty: true)}
          ```
          """

        _error ->
          """
          ```
          #{resp_body}
          ```
          """
      end

    w!(file, w)
  end

  defp camelize_header_key(key) do
    key
    |> String.split("-")
    |> Enum.map(fn
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      other -> other
    end)
    |> Enum.join("-")
  end

  defp w!(file, content) do
    IO.puts(file, content)
  end
end
