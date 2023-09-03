defmodule Web.Actors.Index do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.Actors

  def mount(_params, _session, socket) do
    with {:ok, actors} <-
           Actors.list_actors(socket.assigns.subject, preload: [identities: :provider]),
         {:ok, actor_groups} <- Actors.peek_actor_groups(actors, 3, socket.assigns.subject) do
      {:ok, socket,
       temporary_assigns: [
         actors: actors,
         actor_groups: actor_groups,
         page_title: "Actors"
       ]}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>

    <.page>
      <:title><%= @page_title %></:title>

      <:action navigate={~p"/#{@account}/actors/new"} icon="hero-plus">
        Add a new Actor
      </:action>

      <:content>
        <.table id="actors" rows={@actors} row_id={&"user-#{&1.id}"}>
          <:col :let={actor} label="name" sortable="false">
            <.actor_name_and_role account={@account} actor={actor} />
          </:col>

          <:col :let={actor} label="identifiers" sortable="false">
            <.identity_identifier
              :for={identity <- actor.identities}
              account={@account}
              identity={identity}
            />
          </:col>

          <:col :let={actor} label="groups" sortable="false">
            <.peek peek={@actor_groups[actor.id]}>
              <:empty>
                None
              </:empty>

              <:item :let={group}>
                <.link navigate={~p"/#{@account}/groups/#{group}"}>
                  <.badge>
                    <%= group.name %>
                  </.badge>
                </.link>
              </:item>

              <:tail :let={count}>
                and <%= count %> more.
              </:tail>
            </.peek>
          </:col>

          <:col :let={actor} label="last signed in" sortable="false">
            <.relative_datetime datetime={last_seen_at(actor.identities)} />
          </:col>
        </.table>
      </:content>
    </.page>
    """
  end

  defp last_seen_at(identities) do
    identities
    |> Enum.reject(&is_nil(&1.last_seen_at))
    |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      identity -> identity.last_seen_at
    end
  end
end
