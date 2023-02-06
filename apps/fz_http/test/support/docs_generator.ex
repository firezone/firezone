defmodule DocsGenerator do
  alias FzHttp.Config.Definition

  @keep_req_headers ["authorization"]
  @keep_resp_headers ["content-type", "location"]

  def write(conns, path) do
    write_config_doc!(FzHttp.Config.Definitions, "../../docs/docs/reference/env-vars.mdx")
    File.mkdir_p!(path)
    write_api_doc!(conns, path)
  end

  def write_config_doc!(module, file_path) do
    file = File.open!(file_path, [:write, :utf8])

    w!(file, "---")

    w!(
      file,
      docusaurus_header(
        title: "Environment Variables",
        sidebar_position: 1
      )
    )

    w!(file, "---")

    with {:ok, doc} <- Definition.fetch_doc(module) do
      w!(file, doc)
    end

    w!(file, "## Environment Variable Listing")
    w!(file, "We recommend setting these in your Docker ENV file (`$HOME/.firezone/.env` by")
    w!(file, "default). Required fields in **bold**.")

    keys =
      Enum.flat_map(module.doc_sections(), fn
        {header, description, keys} ->
          w_env_vars!(file, module, header, description, keys)
          keys

        {header, keys} ->
          w_env_vars!(file, module, header, nil, keys)
          keys
      end)

    all_keys = module.configs() |> Enum.map(&elem(&1, 1))
    w_env_vars!(file, module, "Other", nil, all_keys -- keys)
  end

  defp w_env_vars!(_file, _module, _header, _description, []), do: :ok

  defp w_env_vars!(file, module, header, description, keys) do
    w!(file, "### #{header}")
    if description, do: w!(file, description)

    w!(file, "")
    w!(file, "| Env Key | Description      | Format | Default |")
    w!(file, "| ------  | ---------------  | ------ | ------- |")

    for key <- keys do
      with {:ok, doc} <- Definition.fetch_doc(module, key) do
        {type, {resolve_opts, _validate_opts, _dump_opts, _debug_opts}} =
          Definition.fetch_spec_and_opts!(module, key)

        default = Keyword.get(resolve_opts, :default)
        required? = if Keyword.has_key?(resolve_opts, :default), do: false, else: true

        key = FzHttp.Config.Resolver.env_key(key)
        key = if required?, do: "**#{key}**", else: key

        doc = doc_env(doc)

        {type, default} = type_and_default(type, default)

        w!(file, "| #{key} | #{doc} | #{type} | #{default} |")
      end
    end

    w!(file, "")
  end

  defp doc_env(doc) do
    doc
    |> String.trim()
    |> String.replace("\n  * `", "<br />  - `")
    |> String.replace("```json", "```")
    |> String.replace("\n\n", "<br /> <br />")
    |> String.replace("\n", " ")
  end

  defp type_and_default(type, default) when is_function(default),
    do: type_and_default(type, "generated from other env vars")

  defp type_and_default(type, nil),
    do: type_and_default(type, "")

  defp type_and_default(type, []),
    do: type_and_default(type, "[]")

  defp type_and_default({:parameterized, Ecto.Enum, opts}, default) do
    values =
      opts.mappings
      |> Keyword.keys()
      # XXX: We remove legacy keys here to prevent people from using it in new installs
      |> Kernel.--([:smtp, :mailgun, :mandrill, :sendgrid, :post_mark, :sendmail])
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_leading(&1, "Elixir."))
      |> Enum.map(&"`#{&1}`")
      |> Enum.join(", ")

    default =
      default
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")

    {"One of #{values}", "`#{default}`"}
  end

  defp type_and_default(FzHttp.Types.CIDR, default),
    do: {"CIDR", default}

  defp type_and_default(FzHttp.Types.IP, default),
    do: {"IP", default}

  defp type_and_default(FzHttp.Types.IPPort, default),
    do: {"IP with port", default}

  defp type_and_default(:integer, default),
    do: {"integer", default}

  defp type_and_default(:string, default),
    do: {"string", default}

  defp type_and_default(:boolean, default),
    do: {"boolean", default}

  defp type_and_default(:map, default),
    do: {"JSON-encoded map", "`" <> Jason.encode!(default) <> "`"}

  defp type_and_default(:embed, default),
    do: {"JSON-encoded map", "`" <> Jason.encode!(default) <> "`"}

  defp type_and_default({:one_of, types}, default) do
    types =
      types
      |> Enum.map(&type_and_default(&1, default))
      |> Enum.map(&elem(&1, 0))
      |> Enum.map(&to_string/1)
      |> Enum.map(&"`#{&1}`")
      |> Enum.join(", ")

    {"one of #{types}", default}
  end

  defp type_and_default({:array, _}, default),
    do: {"JSON-encoded list", "`" <> Jason.encode!(default) <> "`"}

  defp type_and_default({:array, separator, type}, default) do
    {type, default} = type_and_default(type, default)
    {"a list of #{type} separated by `#{separator}`", default}
  end

  defp type_and_default(type, default) when not is_binary(default),
    do: type_and_default(type, inspect(default))

  defp type_and_default(type, default),
    do: {inspect(type), "`" <> default <> "`"}

  defp write_api_doc!(conns, path) do
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

        title = maybe_wrap(function_assigns[:action], "#{verb} #{path}")

        w!(file, "### #{title}")
        w!(file, "\n")
        w!(file, function_doc)

        uri_params = build_uri_params(path)

        write_examples(file, conns, path, uri_params)
      end)
    end)
  end

  defp maybe_wrap(nil, title), do: title
  defp maybe_wrap(action_assign, title), do: "#{action_assign} [`#{title}`]"

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
