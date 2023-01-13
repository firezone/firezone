defmodule Firezone.DocusaurusWriter do
  @keep_req_headers ["authorization"]
  @keep_resp_headers ["content-type", "location"]

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

        title =
          if action_assign = function_assigns[:action] do
            "#{action_assign} [`#{verb} #{path}`]"
          else
            "#{verb} #{path}"
          end

        w!(file, "### #{title}")
        w!(file, "\n")
        w!(file, function_doc)

        uri_params = build_uri_params(path)

        write_examples(file, conns, path, uri_params)
      end)
    end)
  end

  defp docusaurus_header(assigns) do
    assigns
    |> Enum.map_join("\n", fn {key, value} ->
      "#{key}: #{value}"
    end)
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

  defp write_examples(file, conns, path, uri_params) do
    conns
    |> Enum.sort_by(& &1.status)
    |> Enum.each(fn conn ->
      example_description = conn.assigns.bureaucrat_opts[:example_description] || "Example"
      w!(file, "#### #{example_description}")

      w_req_uri_params!(file, conn, uri_params)

      w!(
        file,
        """
        ```bash
        $ curl -i \\
          -X #{conn.method} "https://{firezone_host}#{path}" \\
          -H 'Content-Type: application/json' \\
        """
        |> String.trim_trailing()
      )

      maybe_w!(file, b_req_headers(conn))
      maybe_w!(file, b_req_body(conn.body_params))

      w!(file, "")

      w!(file, "HTTP/1.1 #{conn.status}")
      maybe_w!(file, b_resp_headers(conn))
      maybe_w!(file, b_resp_body(conn.resp_body))
      w!(file, "```")
    end)
  end

  defp w_req_uri_params!(_file, _conn, []), do: :ok

  defp w_req_uri_params!(file, conn, params) do
    w!(file, "**URI Parameters:**\n")

    Enum.each(params, fn param ->
      w!(file, i(1, "- `#{param}`: `#{conn.params[param]}`"))
    end)
  end

  defp b_req_headers(conn) do
    for {key, value} <- conn.req_headers, key in @keep_req_headers do
      case {key, value} do
        {"authorization", "bearer " <> _} ->
          i(1, "-H 'Authorization: Bearer {api_token}' \\")

        {key, value} ->
          i(1, "-H '#{camelize_header_key(key)}: #{value}' \\")
      end
    end
    |> Enum.join("\n")
  end

  defp b_req_body(params) when params == %{}, do: ""

  defp b_req_body(params) do
    i(1, "--data-binary @- << EOF\n#{Jason.encode!(params, pretty: true)}'\nEOF")
  end

  defp b_resp_headers(conn) do
    for {key, value} <- conn.resp_headers, key in @keep_resp_headers do
      "#{camelize_header_key(key)}: #{value}"
    end
    |> Enum.join("\n")
  end

  defp b_resp_body(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, map} ->
        "\n" <> Jason.encode!(map, pretty: true)

      _error ->
        resp_body
    end
  end

  defp camelize_header_key(key) do
    key
    |> String.split("-")
    |> Enum.map_join("-", fn
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      other -> other
    end)
  end

  defp i(level, text) do
    String.duplicate("  ", level) <> text
  end

  defp maybe_w!(_file, ""), do: :ok
  defp maybe_w!(_file, nil), do: :ok
  defp maybe_w!(file, text), do: w!(file, text)

  defp w!(file, content) do
    IO.puts(file, content)
  end
end
