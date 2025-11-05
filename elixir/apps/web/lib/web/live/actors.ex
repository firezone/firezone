defmodule Web.Actors.IndexNew do
  use Web, :live_view

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Actors")
      |> assign_live_table("actors",
        query_module: __MODULE__.Query,
        hide_filters: [:type],
        sortable_fields: [
          {:actors, :email}
        ],
        callback: &handle_actors_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_actors_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload, [
        :last_seen_at,
        :identities
      ])

    with {:ok, actors, metadata} <- Domain.Actors.list_actors(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, actors: actors, actors_metadata: metadata)}
    end
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"] do
    handle_live_table_event(event, params, socket)
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>

      <:action>
        <.docs_action path="/deploy/users" />
      </:action>

      <:help>
        Actors are the people and services that can access your Resources.
      </:help>

      <:content>
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} class="w-1/12">
            {# TODO: Admin/ServiceAccount/User icon}
          </:col>
          <:col :let={actor} field={{:actors, :email}} label="email" class="w-2/12">
            <span class="block truncate" title={actor.email}>
              {actor.email}
            </span>
          </:col>
          <:col :let={actor} label="name" class="w-2/12">
            {# TODO: identity name}
          </:col>
          <:col :let={actor} label="last seen" class="w-2/12">
            {# TODO: identity last seen}
          </:col>
        </.live_table>
      </:content>
    </.section>
    """
  end

  defmodule Query do
    import Ecto.Query
  end
end
