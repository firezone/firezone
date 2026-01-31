defmodule PortalWeb.Settings.ApiClients.Index do
  use PortalWeb, :live_view

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def list_actors(subject, opts \\ []) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], a.type == :api_client)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end
  end

  def mount(_params, _session, socket) do
    if Portal.Account.rest_api_enabled?(socket.assigns.account) do
      socket =
        socket
        |> assign(page_title: "API Clients")
        |> assign(api_url: Portal.Config.get_env(:portal, :api_external_url))
        |> assign_live_table("actors",
          query_module: Database,
          sortable_fields: [
            {:actors, :name},
            {:actors, :status}
          ],
          callback: &handle_api_clients_update!/2
        )

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/beta")}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_api_clients_update!(socket, list_opts) do
    with {:ok, actors, actors_metadata} <-
           Database.list_actors(socket.assigns.subject, list_opts) do
      socket =
        assign(socket,
          actors: actors,
          actors_metadata: actors_metadata
        )

      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:help>
        API Clients are used to manage Firezone configuration through a REST PortalAPI. See our
        <.link navigate={"#{@api_url}/swaggerui"} class={link_style()} target="_blank">
          OpenAPI-powered docs
        </.link>
        for more information.
      </:help>

      <:action>
        <.docs_action path="/reference/rest-api" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/settings/api_clients/new"}>
          Add API Client
        </.add_button>
      </:action>
      <:content>
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"api-client-#{&1.id}"}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} label="name">
            <.link navigate={~p"/#{@account}/settings/api_clients/#{actor}"} class={link_style()}>
              {actor.name}
            </.link>
          </:col>
          <:col :let={actor} label="status">
            <.badge type={badge_type(actor)}>
              {status(actor)}
            </.badge>
          </:col>
          <:col :let={actor} label="created at">
            {PortalWeb.Format.short_date(actor.inserted_at)}
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No API Clients to display.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  defp status(actor) do
    if is_nil(actor.disabled_at), do: "Active", else: "Disabled"
  end

  defp badge_type(actor) do
    if is_nil(actor.disabled_at), do: "success", else: "danger"
  end
end
