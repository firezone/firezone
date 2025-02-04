defmodule Web.Settings.ApiClients.NewToken do
  use Web, :live_view
  import Web.Settings.ApiClients.Components
  alias Domain.{Auth, Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    unless Domain.Config.global_feature_enabled?(:rest_api),
      do: raise(Web.LiveErrors.NotFoundError)

    with {:ok, %{type: :api_client} = actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject) do
      changeset = Tokens.Token.Changeset.create(%{})

      socket =
        assign(socket,
          actor: actor,
          encoded_token: nil,
          form: to_form(changeset),
          page_title: "New API Token"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/#{@actor}"}>
        {@actor.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/#{@actor}/new_token"}>
        Add Token
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <div :if={is_nil(@encoded_token)}>
            <h2 class="mb-4 text-xl text-neutral-900">API Token details</h2>
            <.flash kind={:error} flash={@flash} />
            <.form for={@form} phx-change={:change} phx-submit={:submit}>
              <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
                <.api_token_form form={@form} />
              </div>
              <.submit_button>
                Create API Token
              </.submit_button>
            </.form>
          </div>

          <div :if={not is_nil(@encoded_token)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
            <.api_token_reveal encoded_token={@encoded_token} account={@account} actor={@actor} />
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"token" => attrs}, socket) do
    attrs = map_expires_at(attrs)

    changeset =
      Tokens.Token.Changeset.create(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"token" => attrs}, socket) do
    attrs = map_expires_at(attrs)

    with {:ok, encoded_token} <-
           Auth.create_api_client_token(
             socket.assigns.actor,
             attrs,
             socket.assigns.subject
           ) do
      {:noreply, assign(socket, encoded_token: encoded_token)}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp map_expires_at(attrs) do
    Map.update(attrs, "expires_at", nil, fn
      nil -> nil
      "" -> ""
      value -> "#{value}T00:00:00.000000Z"
    end)
  end
end
