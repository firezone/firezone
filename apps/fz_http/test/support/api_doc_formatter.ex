defmodule Firezone.ApiBlueprintWriter do
  @keep_req_headers []
  @keep_resp_headers ["content-type", "location"]

  def write(conns, path) do
    file = File.open!(path, [:write, :utf8])

    # conns =
    #   conns
    #   |> filter_conns()
    #   |> assign_doc_attributes()

    open_api_spec = %{
      openapi: "3.0.0",
      info: %{
        title: "Firezone API",
        version: "0.1.0",
        contact: %{
          name: "Firezone Issue Tracker",
          url: "https://github.com/firezone/firezone/issues"
        },
        license: %{
          name: "Apache License 2.0",
          url: "https://github.com/firezone/firezone/blob/master/LICENSE"
        }
      },
      components: %{
        securitySchemes: %{
          api_key: %{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT"
          }
        }
      },
      paths: build_paths(conns)
    }

    IO.puts(file, Jason.encode!(open_api_spec, pretty: true))
  end

  defp build_paths(conns) do
    routes = Phoenix.Router.routes(List.first(conns).private.phoenix_router)

    conns
    |> Enum.group_by(& &1.private.phoenix_controller)
    |> Enum.map(fn {controller, conns} ->
      {_moduledoc, module_api_doc, function_docs} = fetch_module_docs!(controller)

      conns
      |> Enum.group_by(& &1.private.phoenix_action)
      |> Enum.map(fn {action, conns} ->
        {path, verb} = fetch_route!(routes, controller, action)
        {path, %{verb => sample_conns(conns, verb, path, module_api_doc, function_docs)}}
      end)
      |> group_by_pop()
      |> Enum.map(fn {key, maps} ->
        {key, merge_maps_list(maps)}
      end)
      |> Enum.into(%{})
    end)
    |> merge_maps_list()
    |> IO.inspect()
  end

  defp fetch_route!(routes, controller, controller_action) do
    %{path: path, verb: verb} =
      Enum.find(routes, fn
        %{plug: ^controller, plug_opts: ^controller_action} -> true
        _other -> false
      end)

    path = String.replace(path, ~r|:([^/]*)|, "{\\1}")

    {path, verb}
  end

  defp merge_maps_list(maps) do
    Enum.reduce(maps, %{}, fn map, acc ->
      Map.merge(acc, map)
    end)
  end

  defp group_by_pop(tuples) do
    tuples
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case acc do
        %{^key => existing} -> %{acc | key => [value | existing]}
        %{} -> Map.put(acc, key, [value])
      end
    end)
  end

  defp fetch_module_docs!(controller) do
    case Code.fetch_docs(controller) do
      {:docs_v1, _, _, _, moduledoc, %{api_doc: module_api_doc}, function_docs} ->
        {get_doc(moduledoc), module_api_doc, function_docs}

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
      {_, _, _, :none, %{api_doc: api_doc}} ->
        {nil, api_doc}

      {_, _, _, doc, %{api_doc: api_doc}} ->
        {get_doc(doc), api_doc}

      {_, _, _, doc, _chunks} ->
        {get_doc(doc), %{}}

      _other ->
        {nil, %{}}
    end
  end

  defp sample_conns([conn | _] = conns, verb, path, module_api_doc, function_docs) do
    action = conn.private.phoenix_action
    {description, assigns} = get_function_docs(function_docs, conn.private.phoenix_action)
    summary = Keyword.get(assigns, :summary, action)
    # parameters = Keyword.get(assigns, :parameters, [])

    responses =
      for conn <- conns, into: %{} do
        {conn.status, build_response(conn, module_api_doc, assigns)}
      end

    header_params =
      for {key, _value} <- conn.req_headers, key in @keep_req_headers do
        %{
          name: camelize_header_key(key),
          in: "header",
          required: false,
          schema: %{
            type: "string"
          }
        }
      end

    uri_params =
      Regex.scan(~r/{([^}]*)}/, path)
      |> Enum.map(fn [_, param] ->
        %{
          name: param,
          in: "path",
          required: true,
          schema: %{
            type: "string"
          }
        }
      end)

    request_body_map =
      if verb == :get do
        %{}
      else
        %{requestBody: %{content: %{"application/json" => %{example: conn.body_params}}}}
      end

    %{
      summary: summary,
      description: description,
      parameters: header_params ++ uri_params,
      security: [
        %{api_key: []}
      ],
      responses: responses
    }
    |> Map.merge(request_body_map)
  end

  defp build_response(conn, _module_api_doc, _assigns) do
    resp_headers =
      for {key, _value} <- conn.resp_headers, key in @keep_resp_headers, into: %{} do
        {key, %{schema: %{type: "string"}}}
      end

    content_type =
      case Plug.Conn.get_resp_header(conn, "content-type") do
        [content_type] ->
          content_type
          |> String.split(";")
          |> List.first()

        [] ->
          "application/json"
      end

    %{
      description: conn.assigns.bureaucrat_opts[:title] || "Description",
      headers: resp_headers,
      content: %{
        content_type => %{examples: %{example: %{value: body_example(conn.resp_body)}}}
      }
    }
  end

  defp body_example(body) do
    with {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> body
    end
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

  ####

  # defp build_params([{:group, {name, child}} | rest], file, ident) do
  #   puts(file, indent_lines(ident, "+ #{name} (object, required)"))
  #   do_write_attribute(child, file, ident + 4)
  #   do_write_attribute(rest, file, ident)
  # end

  # defp do_write_attribute(
  #        [{:attr, {name, {:type, type}, required?, description}} | rest],
  #        file,
  #        ident
  #      ) do
  #   puts(
  #     file,
  #     indent_lines(ident, "+ #{name}" <> type_info(type, required?) <> description(description))
  #   )

  #   maybe_write_enum(type, file, ident + 4)
  #   do_write_attribute(rest, file, ident)
  # end

  # defp type_info({:enum, _type, _values, example}, required?),
  #   do: "#{example(example)} (enum, #{required(required?)})"

  # defp type_info({type, example}, required?),
  #   do: "#{example(example)} (#{type}, #{required(required?)})"

  # defp type_info(type, required?),
  #   do: " (#{type}, #{required(required?)})"

  # defp example(example) when is_binary(example), do: ": `#{example}`"
  # defp example(example), do: ": #{example}"

  # defp required(true), do: "required"
  # defp required(false), do: "optional"

  # defp description(nil), do: ""
  # defp description(description), do: " - #{description}"

  # defp maybe_write_enum({:enum, type, values, _example}, file, ident) do
  #   Enum.each(values, fn value ->
  #     puts(file, indent_lines(ident, "- `#{value}` (#{type})"))
  #   end)
  # end

  # defp maybe_write_enum(_other, _file, _ident) do
  #   :ok
  # end

  # defp write_request_body(params, file) do
  #   case params == %{} do
  #     true ->
  #       nil

  #     false ->
  #       file
  #       |> puts(indent_lines(4, "+ Body\n"))
  #       |> puts(indent_lines(12, format_request_body(params)))
  #   end
  # end

  # defp write_response(record, file) do
  #   file |> puts("\n+ Response #{record.status}\n")
  #   write_headers(record.resp_headers, file)
  #   write_response_body(record.resp_body, file)
  # end

  # defp write_response_body(params, _file) when map_size(params) == 0, do: nil

  # defp write_response_body(params, file) do
  #   file
  #   |> puts(indent_lines(4, "+ Body\n"))
  #   |> puts(indent_lines(12, format_response_body(params)))
  # end

  # def format_request_body(params) do
  #   {:ok, json} = JSON.encode(params, pretty: true)
  #   json
  # end

  # defp format_response_body("") do
  #   ""
  # end

  # defp format_response_body(string) do
  #   {:ok, struct} = JSON.decode(string)
  #   {:ok, json} = JSON.encode(struct, pretty: true)
  #   json
  # end

  # def indent_lines(number_of_spaces, string) do
  #   String.split(string, "\n")
  #   |> Enum.map(fn a -> String.pad_leading("", number_of_spaces) <> a end)
  #   |> Enum.join("\n")
  # end

  # def formatted_params(uri_params) do
  #   Enum.map(uri_params, &format_param/1) |> Enum.join("\n")
  # end

  # def format_param(param) do
  #   "    + #{URI.encode(elem(param, 0))}: `#{URI.encode(elem(param, 1))}`"
  # end

  # def anchor(record = %{path_params: path_params}) when map_size(path_params) == 0 do
  #   record.request_path
  # end

  # def anchor(record) do
  #   Enum.join([""] ++ set_params(record), "/")
  # end

  # defp set_params(record) do
  #   Enum.flat_map(record.path_info, fn part ->
  #     case Enum.find(record.path_params, fn {_key, val} -> val == part end) do
  #       {param, _} -> ["{#{param}}"]
  #       nil -> [part]
  #     end
  #   end)
  # end

  # defp puts(file, string) do
  #   IO.puts(file, string)
  #   file
  # end

  # def controller_name(module) do
  #   prefix = Application.get_env(:bureaucrat, :prefix)

  #   Regex.run(~r/#{prefix}(.+)/, module, capture: :all_but_first)
  #   |> List.first()
  #   |> String.trim("Controller")
  #   |> Inflex.pluralize()
  # end

  # defp group_records(records) do
  #   by_controller = Bureaucrat.Util.stable_group_by(records, &get_controller/1)

  #   Enum.map(by_controller, fn {c, recs} ->
  #     {c, Bureaucrat.Util.stable_group_by(recs, &get_action/1)}
  #   end)
  # end

  # defp strip_ns(module) do
  #   case to_string(module) do
  #     "Elixir." <> rest -> rest
  #     other -> other
  #   end
  # end

  # defp get_controller(conn) do
  #   conn.assigns.api_doc[:group] ||
  #     conn.assigns.bureaucrat_opts[:group] || strip_ns(conn.private.phoenix_controller)
  # end

  # defp get_action(conn) do
  #   IO.inspect({conn.private.phoenix_controller, conn.private.phoenix_action})
  #   Keyword.fetch!(conn.assigns.api_doc, :action)
  # end
end
