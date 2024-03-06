defmodule Web.LiveHelpers do
  use Phoenix.LiveView
  alias Domain.{Auth, Actors, Resources}

  def handle_rich_table_params(params, uri, socket, name, query_module, default_params \\ []) do
    filter = params_to_filter(name, params)
    page = params_to_page(params)
    order_by = params_to_order_by(socket.assigns.sortable_fields, params)

    list_opts =
      [
        page: page,
        filter: filter,
        order_by: List.wrap(order_by)
      ] ++ default_params

    socket =
      assign(socket,
        uri: uri,
        params: params,
        filter: filter_to_form(filter, name),
        filters: preload_filters(query_module, socket.assigns.subject),
        order_by: order_by
      )

    {socket, list_opts}
  end

  defp preload_filters(query_module, subject) do
    query_module
    |> Domain.Repo.Query.get_filters()
    |> Enum.map(&preload_values(&1, query_module, subject))
  end

  defp preload_values(%{name: :provider_id} = filter, Actors.Group.Query, subject),
    do: %{filter | values: Auth.all_third_party_provider_options!(subject)}

  defp preload_values(%{name: :provider_id} = filter, _query_module, subject),
    do: %{filter | values: Auth.all_provider_options!(subject)}

  defp preload_values(%{name: :actor_id} = filter, _query_module, subject),
    do: %{filter | values: Actors.all_actor_options!(subject)}

  defp preload_values(%{name: :resource_id} = filter, _query_module, subject),
    do: %{filter | values: Resources.all_resource_options!(subject)}

  defp preload_values(%{name: :actor_group_id} = filter, _query_module, subject),
    do: %{filter | values: Actors.all_group_options!(subject)}

  defp preload_values(filter, _query_module, _subject),
    do: filter

  defp params_to_page(%{"cursor" => cursor}), do: [cursor: cursor]
  defp params_to_page(_params), do: []

  defp params_to_filter(name, %{"filter" => filter}) do
    for {key, value} <- Map.get(filter, name, []), value != "" do
      {String.to_existing_atom(key), value}
    end
  end

  defp params_to_filter(_name, %{}) do
    []
  end

  defp filter_to_form(filter, as) do
    # Note: we don't support nesting, :and or :where on the UI yet
    for {key, value} <- filter, into: %{} do
      {Atom.to_string(key), value}
    end
    |> to_form(as: as)
  end

  defp params_to_order_by(sortable_fields, %{"order_by" => field}) do
    with [field_assoc, field_direction, field_field] <- String.split(field, ":", parts: 3),
         {assoc, field} <-
           Enum.find(sortable_fields, fn {assoc, field} ->
             to_string(assoc) == field_assoc && to_string(field) == field_field
           end),
         field_direction when field_direction in ["asc", "desc"] <- field_direction do
      {assoc, String.to_existing_atom(field_direction), field}
    else
      _other -> nil
    end
  end

  defp params_to_order_by(_sortable_fields, _params) do
    nil
  end

  defp order_by_to_params({assoc, direction, field}),
    do: %{"order_by" => "#{assoc}:#{direction}:#{field}"}

  defp order_by_to_params(nil),
    do: %{}

  defp reverse_order_by({assoc, :asc, field}), do: {assoc, :desc, field}
  defp reverse_order_by({assoc, :desc, field}), do: {assoc, :asc, field}
  defp reverse_order_by(nil), do: nil

  defp update_query_params(socket, update_fun) when is_function(update_fun, 1) do
    uri = URI.parse(socket.assigns.uri)

    query =
      URI.decode_query(uri.query || "")
      |> update_fun.()
      |> URI.encode_query()

    {:noreply, push_patch(socket, to: "#{uri.path}?#{query}")}
  end

  def handle_rich_table_event("paginate", %{"cursor" => cursor}, socket) do
    update_query_params(socket, fn query_params ->
      Map.put(query_params, "cursor", cursor)
    end)
  end

  def handle_rich_table_event("order_by", params, socket) do
    update_query_params(socket, fn query_params ->
      order_by_params =
        params_to_order_by(socket.assigns.sortable_fields, params)
        |> reverse_order_by()
        |> order_by_to_params()

      query_params
      |> Map.delete("cursor")
      |> Map.delete("order_by")
      |> Map.merge(order_by_params)
    end)
  end

  def handle_rich_table_event("filter", %{"_target" => [id, _field]} = params, socket) do
    %{^id => filter} = params

    update_query_params(socket, fn query_params ->
      filter =
        for {key, value} <- filter, value != "", into: %{} do
          {"filter[#{id}][#{key}]", value}
        end

      query_params
      |> Map.delete("cursor")
      |> Map.filter(fn {k, _} -> not String.starts_with?(k, "filter[") end)
      |> Map.merge(filter)
    end)
  end
end
