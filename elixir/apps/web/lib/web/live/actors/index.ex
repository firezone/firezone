defmodule Web.Actors.Index do
  use Web, :live_view
  import Web.Actors.Components
  import Web.Clients.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Actors")
      |> assign_live_table("actors",
        query_module: Actors.Actor.Query,
        hide_filters: [:type],
        sortable_fields: [
          {:actors, :name}
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
        identities: :provider
      ])

    with {:ok, actors, metadata} <- Actors.list_actors(socket.assigns.subject, list_opts),
         {:ok, actor_groups} <- Actors.peek_actor_groups(actors, 3, socket.assigns.subject),
         {:ok, actor_clients} <- Actors.peek_actor_clients(actors, 5, socket.assigns.subject) do
      {:ok,
       assign(socket,
         actors: actors,
         actors_metadata: metadata,
         actor_groups: actor_groups,
         actor_clients: actor_clients
       )}
    end
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

      <:action>
        <.add_button navigate={~p"/#{@account}/actors/new"}>
          Add Actor
        </.add_button>
      </:action>

      <:help>
        Actors are the people and services that can access your Resources.
      </:help>

      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"user-#{&1.id}"}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} field={{:actors, :name}} label="name" class="w-2/12">
            <span class="block truncate" title={actor.name}>
              <.actor_name_and_role account={@account} actor={actor} />
            </span>
          </:col>

          <:col :let={actor} label="identifiers">
            <div class="flex flex-wrap gap-y-2">
              <.identity_identifier
                :for={identity <- actor.identities}
                account={@account}
                identity={identity}
              />
            </div>
          </:col>

          <:col :let={actor} label="groups" class="w-1/12">
            <span :if={actor.type == :api_client}>None</span>
            <.popover :if={actor.type != :api_client} placement="right">
              <:target>
                <.link
                  navigate={~p"/#{@account}/actors/#{actor}?#groups"}
                  class={[
                    "hover:underline hover:decoration-line",
                    "underline underline-offset-2 decoration-1 decoration-dotted",
                    link_style()
                  ]}
                >
                  {@actor_groups[actor.id].count}
                </.link>
              </:target>
              <:content>
                <.peek peek={@actor_groups[actor.id]}>
                  <:empty>
                    None
                  </:empty>

                  <:item :let={group}>
                    <div class="flex flex-wrap gap-y-2 mr-2">
                      <.group account={@account} group={group} />
                    </div>
                  </:item>

                  <:tail :let={count}>
                    <span class="inline-block whitespace-nowrap">
                      and {count} more.
                    </span>
                  </:tail>
                </.peek>
              </:content>
            </.popover>
          </:col>

          <:col :let={actor} label="clients" class="w-2/12">
            <.peek peek={@actor_clients[actor.id]}>
              <:empty>
                None
              </:empty>

              <:item :let={client}>
                <.link navigate={~p"/#{@account}/clients/#{client}"} class="mr-2">
                  <.client_as_icon client={client} />
                  <div class="relative">
                    <div class="absolute -inset-y-2.5 -right-1">
                      <.online_icon schema={client} />
                    </div>
                  </div>
                </.link>
              </:item>

              <:tail :let={count}>
                <span class="inline-block whitespace-nowrap flex">
                  <span>and</span>
                  <.link
                    navigate={~p"/#{@account}/actors/#{actor}?#clients"}
                    class={["inline-flex ml-1", link_style()]}
                  >
                    {count} more
                  </.link>
                  <span>.</span>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:col :let={actor} label="status" class="w-1/12">
            <.actor_status actor={actor} />
          </:col>

          <:col :let={actor} label="last signed in" class="w-1/12">
            <.relative_datetime datetime={actor.last_seen_at} />
          </:col>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
