defmodule Web.Settings.ApiClients.Index do
  use Web, :live_view
  alias Domain.{Actors, Tokens}

  def mount(_params, _session, socket) do
    unless Domain.Config.global_feature_enabled?(:api_client_ui),
      do: raise(Web.LiveErrors.NotFoundError)

    with {:ok, actors} <- Actors.list_actors_by_type(socket.assigns.subject, :api_client),
         {:ok, tokens} <- Tokens.list_tokens_by_type(:api_client, socket.assigns.subject) do
      token_count =
        Enum.reduce(tokens, %{}, fn %{actor_id: actor_id}, acc ->
          Map.update(acc, actor_id, 1, &(&1 + 1))
        end)

      socket =
        assign(socket,
          actors: actors,
          token_count: token_count,
          page_title: "API Clients"
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>

      <:action>
        <.add_button navigate={~p"/#{@account}/settings/api_clients/new"}>
          Add API Client
        </.add_button>
      </:action>
      <:content>
        <.table id="actors" rows={@actors} row_id={&"api-client-#{&1.id}"}>
          <:col :let={actor} label="name" sortable="false">
            <.link navigate={~p"/#{@account}/settings/api_clients/#{actor}"} class={link_style()}>
              <%= actor.name %>
            </.link>
          </:col>
          <:col :let={actor} label="status" sortable="false">
            <%= status(actor) %>
          </:col>
          <:col :let={actor} label="tokens" sortable="false">
            <%= Map.get(@token_count, actor.id, 0) %>
          </:col>
          <:col :let={actor} label="created at" sortable="false">
            <%= Cldr.DateTime.Formatter.date(actor.inserted_at, 1, "en", Web.CLDR, []) %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No API Clients to display.
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>
    """
  end

  defp status(actor) do
    if Actors.actor_active?(actor), do: "Active", else: "Disabled"
  end
end
