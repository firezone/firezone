defmodule Web.Actors.ServiceAccounts.NewIdentity do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Auth, Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, %{type: :service_account} = actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject) do
      changeset = Tokens.Token.Changeset.create(%{})

      socket =
        assign(socket,
          actor: actor,
          encoded_token: nil,
          form: to_form(changeset),
          page_title: "New Service Account Token"
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}>
        Add Token
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Create <%= actor_type(@actor.type) %> Token
      </:title>
      <:content>
        <div :if={is_nil(@encoded_token)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Create a Token</h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input label="Name" field={@form[:name]} placeholder="Name for this token" required />
              </div>

              <div>
                <.input
                  label="Expires At"
                  type="date"
                  field={@form[:expires_at]}
                  min={Date.utc_today()}
                  value={Date.utc_today() |> Date.add(365)}
                  placeholder="When the token should auto-expire"
                  required
                />
              </div>
            </div>
            <.submit_button>
              Save
            </.submit_button>
          </.form>
        </div>

        <div :if={not is_nil(@encoded_token)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div class="text-xl mb-2">
              Your API token (will be shown only once):
            </div>

            <.code_block id="code-sample-docker" class="w-full mw-1/2 rounded" phx-no-format><%= @encoded_token %></.code_block>

            <.button icon="hero-arrow-uturn-left" navigate={~p"/#{@account}/actors/#{@actor}"}>
              Back to Actor
            </.button>
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
           Auth.create_service_account_token(
             socket.assigns.actor,
             socket.assigns.subject,
             attrs
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
