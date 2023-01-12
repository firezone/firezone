defmodule Firezone.ApiBlueprintWriter do
  alias Bureaucrat.JSON

  @title "Firezone API"

  @description """
  This is Firezone documentation.
  """

  @keep_req_headers ["authorization"]
  @keep_resp_headers ["content-type", "location"]

  def write(records, path) do
    records =
      records
      |> filter_records()
      |> assign_doc_attributes()

    file = File.open!(path, [:write, :utf8])
    records = group_records(records)
    puts(file, "# #{@title}\n#{@description}")
    write_intro(path, file)
    write_api_doc(records, file)
  end

  defp filter_records(records) do
    Enum.map(records, fn conn ->
      %{
        conn
        | req_headers: filter_headers(conn.req_headers, @keep_req_headers),
          resp_headers: filter_headers(conn.resp_headers, @keep_resp_headers)
      }
    end)
  end

  defp filter_headers(headers, keep) do
    headers
    |> Enum.filter(fn {header, _value} -> header in keep end)
    |> Enum.map(fn
      {"authorization", _value} ->
        {"Authorization", "Bearer {api_token}"}

      {header, value} ->
        {camelize_header_key(header), value}
    end)
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

  defp assign_doc_attributes(records) do
    Enum.map(records, fn conn ->
      case Code.fetch_docs(conn.private.phoenix_controller) do
        {:docs_v1, _, _, _, md, %{api_doc: api_doc_opts}, function_docs} ->
          fun_api_doc_opts =
            get_function_doc_attributes(function_docs, conn.private.phoenix_action)

          api_doc_opts = Keyword.merge(api_doc_opts, fun_api_doc_opts)
          api_doc_opts = Keyword.put(api_doc_opts, :moduledoc, doc(md))
          assigns = Map.put(conn.assigns, :api_doc, api_doc_opts)
          %{conn | assigns: assigns}

        {:error, :module_not_found} ->
          raise "No module #{conn.private.phoenix_controller}"
      end
    end)
  end

  defp doc(md) when is_map(md), do: Map.get(md, "en")
  defp doc(_md), do: nil

  defp get_function_doc_attributes(function_docs, function) do
    function_docs
    |> Enum.find(fn {{:function, doc_function, _}, _, _, _, _} ->
      doc_function == function
    end)
    |> case do
      {_, _, _, md, %{api_doc: api_doc_opts}} when is_map(md) ->
        api_doc_opts ++ [function_doc: doc(md)]

      _other ->
        []
    end
  end

  defp write_intro(path, file) do
    intro_file_path =
      [
        # /path/to/API.md -> /path/to/API_INTRO.md
        String.replace(path, ~r/\.md$/i, "_INTRO\\0"),
        # /path/to/api.md -> /path/to/api_intro.md
        String.replace(path, ~r/\.md$/i, "_intro\\0"),
        # /path/to/API -> /path/to/API_INTRO
        "#{path}_INTRO",
        # /path/to/api -> /path/to/api_intro
        "#{path}_intro"
      ]
      # which one exists?
      |> Enum.find(nil, &File.exists?/1)

    if intro_file_path do
      file
      |> puts(File.read!(intro_file_path))
      |> puts("\n\n## Endpoints\n\n")
    else
      puts(file, "# API Documentation\n")
    end
  end

  defp write_api_doc(records, file) do
    Enum.each(records, fn {controller, actions} ->
      %{request_path: path} = Enum.at(actions, 0) |> elem(1) |> List.first()
      puts(file, "\n## #{controller} [#{path}]")

      with {_action, [conn | _]} <- List.first(actions) do
        if moduledoc = conn.assigns.api_doc[:moduledoc] do
          puts(file, "\n#{moduledoc}")
        end
      end

      Enum.each(actions, fn {action, records} ->
        write_action(action, Enum.reverse(records), file)
      end)
    end)

    puts(file, "")
  end

  defp write_action(action, records, file) do
    test_description = to_string(action)
    record_request = Enum.at(records, 0)
    method = record_request.method

    puts(file, "### #{test_description} [#{method} #{anchor(record_request)}]")

    if function_doc = record_request.assigns.api_doc[:function_doc] do
      puts(file, "\n#{function_doc}")
    end

    write_parameters(record_request.path_params, file)

    records
    |> sort_by_status_code()
    |> Enum.each(&write_example(&1, file))
  end

  defp write_parameters(path_params, _file) when map_size(path_params) == 0, do: nil

  defp write_parameters(path_params, file) do
    puts(file, "\n+ Parameters\n#{formatted_params(path_params)}")
  end

  defp sort_by_status_code(records) do
    records |> Enum.sort_by(& &1.status)
  end

  defp write_example(record, file) do
    write_request(record, file)
    write_response(record, file)
  end

  defp write_request(record, file) do
    request_name =
      if title = Keyword.get(record.assigns.bureaucrat_opts, :title) do
        title
      else
        "#{record.method} #{record.request_path}"
      end

    puts(file, "\n\n+ Request #{request_name}")

    if subtitle = Keyword.get(record.assigns.bureaucrat_opts, :subtitle) do
      puts(file, "#{subtitle}\n")
    end

    write_headers(record.req_headers, file)
    write_attributes(record.assigns.api_doc[:action_params], file)
    write_request_body(record.body_params, file)
  end

  defp write_headers(_headers = [], _file), do: nil

  defp write_headers(headers, file) do
    file |> puts(indent_lines(4, "+ Headers\n"))

    Enum.each(headers, fn {header, value} ->
      puts(file, indent_lines(12, "#{header}: #{value}"))
    end)

    file
  end

  defp write_attributes(nil, _file), do: nil

  defp write_attributes(params, file) do
    puts(file, indent_lines(4, "\n+ Attributes (object)\n"))
    do_write_attribute(params, file, 8)
    puts(file, "\n")
  end

  defp do_write_attribute([], _file, _ident) do
    :ok
  end

  defp do_write_attribute([{:group, {name, child}} | rest], file, ident) do
    puts(file, indent_lines(ident, "+ #{name} (object, required)"))
    do_write_attribute(child, file, ident + 4)
    do_write_attribute(rest, file, ident)
  end

  defp do_write_attribute(
         [{:attr, {name, {:type, type}, required?, description}} | rest],
         file,
         ident
       ) do
    puts(
      file,
      indent_lines(ident, "+ #{name}" <> type_info(type, required?) <> description(description))
    )

    maybe_write_enum(type, file, ident + 4)
    do_write_attribute(rest, file, ident)
  end

  defp type_info({:enum, _type, _values, example}, required?),
    do: "#{example(example)} (enum, #{required(required?)})"

  defp type_info({type, example}, required?),
    do: "#{example(example)} (#{type}, #{required(required?)})"

  defp type_info(type, required?),
    do: " (#{type}, #{required(required?)})"

  defp example(example) when is_binary(example), do: ": `#{example}`"
  defp example(example), do: ": #{example}"

  defp required(true), do: "required"
  defp required(false), do: "optional"

  defp description(nil), do: ""
  defp description(description), do: " - #{description}"

  defp maybe_write_enum({:enum, type, values, _example}, file, ident) do
    Enum.each(values, fn value ->
      puts(file, indent_lines(ident, "- `#{value}` (#{type})"))
    end)
  end

  defp maybe_write_enum(_other, _file, _ident) do
    :ok
  end

  defp write_request_body(params, file) do
    case params == %{} do
      true ->
        nil

      false ->
        file
        |> puts(indent_lines(4, "+ Body\n"))
        |> puts(indent_lines(12, format_request_body(params)))
    end
  end

  defp write_response(record, file) do
    file |> puts("\n+ Response #{record.status}\n")
    write_headers(record.resp_headers, file)
    write_response_body(record.resp_body, file)
  end

  defp write_response_body(params, _file) when map_size(params) == 0, do: nil

  defp write_response_body(params, file) do
    file
    |> puts(indent_lines(4, "+ Body\n"))
    |> puts(indent_lines(12, format_response_body(params)))
  end

  def format_request_body(params) do
    {:ok, json} = JSON.encode(params, pretty: true)
    json
  end

  defp format_response_body("") do
    ""
  end

  defp format_response_body(string) do
    {:ok, struct} = JSON.decode(string)
    {:ok, json} = JSON.encode(struct, pretty: true)
    json
  end

  def indent_lines(number_of_spaces, string) do
    String.split(string, "\n")
    |> Enum.map(fn a -> String.pad_leading("", number_of_spaces) <> a end)
    |> Enum.join("\n")
  end

  def formatted_params(uri_params) do
    Enum.map(uri_params, &format_param/1) |> Enum.join("\n")
  end

  def format_param(param) do
    "    + #{URI.encode(elem(param, 0))}: `#{URI.encode(elem(param, 1))}`"
  end

  def anchor(record = %{path_params: path_params}) when map_size(path_params) == 0 do
    record.request_path
  end

  def anchor(record) do
    Enum.join([""] ++ set_params(record), "/")
  end

  defp set_params(record) do
    Enum.flat_map(record.path_info, fn part ->
      case Enum.find(record.path_params, fn {_key, val} -> val == part end) do
        {param, _} -> ["{#{param}}"]
        nil -> [part]
      end
    end)
  end

  defp puts(file, string) do
    IO.puts(file, string)
    file
  end

  def controller_name(module) do
    prefix = Application.get_env(:bureaucrat, :prefix)

    Regex.run(~r/#{prefix}(.+)/, module, capture: :all_but_first)
    |> List.first()
    |> String.trim("Controller")
    |> Inflex.pluralize()
  end

  defp group_records(records) do
    by_controller = Bureaucrat.Util.stable_group_by(records, &get_controller/1)

    Enum.map(by_controller, fn {c, recs} ->
      {c, Bureaucrat.Util.stable_group_by(recs, &get_action/1)}
    end)
  end

  defp strip_ns(module) do
    case to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp get_controller(conn) do
    conn.assigns.api_doc[:group] ||
      conn.assigns.bureaucrat_opts[:group] || strip_ns(conn.private.phoenix_controller)
  end

  defp get_action(conn) do
    conn.assigns.api_doc[:action] ||
      conn.assigns.bureaucrat_opts[:action] ||
      conn.private.phoenix_action
  end
end
