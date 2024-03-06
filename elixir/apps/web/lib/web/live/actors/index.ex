defmodule Web.Actors.Index do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    sortable_fields = [
      {:actors, :name}
    ]

    {:ok, assign(socket, page_title: "Actors", sortable_fields: sortable_fields)}
  end

  def handle_params(params, uri, socket) do
    {socket, list_opts} =
      handle_rich_table_params(params, uri, socket, "actors", Actors.Actor.Query,
        preload: [identities: :provider]
      )

    with {:ok, actors, metadata} <- Actors.list_actors(socket.assigns.subject, list_opts),
         {:ok, actor_groups} <- Actors.peek_actor_groups(actors, 3, socket.assigns.subject) do
      socket =
        assign(socket,
          actors: actors,
          actor_groups: actor_groups,
          metadata: metadata
        )

      {:noreply, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>

      <:action>
        <.add_button navigate={~p"/#{@account}/actors/new"}>
          Add Actor
        </.add_button>
      </:action>
      <:help>
        Actors are the people and services that can access your resources.
      </:help>
      <:content>
        <.rich_table
          id="actors"
          rows={@actors}
          row_id={&"user-#{&1.id}"}
          sortable_fields={@sortable_fields}
          filters={@filters}
          filter={@filter}
          metadata={@metadata}
        >
          <:col :let={actor} label="name" field={{:actors, :name}} order_by={@order_by}>
            <.actor_name_and_role account={@account} actor={actor} />
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

          <:col :let={actor} label="groups">
            <.peek peek={@actor_groups[actor.id]}>
              <:empty>
                None
              </:empty>

              <:item :let={group}>
                <.group account={@account} group={group} />
              </:item>

              <:tail :let={count}>
                <span class="inline-block whitespace-nowrap">
                  and <%= count %> more.
                </span>
              </:tail>
            </.peek>
          </:col>

          <:col :let={actor} label="last signed in">
            <.relative_datetime datetime={last_seen_at(actor.identities)} />
          </:col>
        </.rich_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_rich_table_event(event, params, socket)
end
