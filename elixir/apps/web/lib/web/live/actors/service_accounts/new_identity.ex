defmodule Web.Actors.ServiceAccounts.NewIdentity do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Auth, Actors}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, %{type: :service_account} = actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject),
         {:ok, provider} <- Auth.fetch_active_provider_by_adapter(:token, socket.assigns.subject) do
      changeset =
        Auth.new_identity(actor, provider, %{
          provider_identifier: "tok-" <> Ecto.UUID.generate()
        })

      socket =
        assign(socket,
          actor: actor,
          provider: provider,
          encoded_token: nil,
          form: to_form(changeset)
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
                <.input
                  label="Name"
                  field={@form[:provider_identifier]}
                  placeholder="Name for this token"
                  required
                />
              </div>

              <.provider_form :if={@provider} form={@form} provider={@provider} />
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

  def handle_event("change", %{"identity" => attrs}, socket) do
    attrs = map_expires_at(attrs)

    changeset =
      Auth.new_identity(socket.assigns.actor, socket.assigns.provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"identity" => attrs}, socket) do
    attrs = map_expires_at(attrs)

    with {:ok, identity} <-
           Auth.create_identity(
             socket.assigns.actor,
             socket.assigns.provider,
             attrs,
             socket.assigns.subject
           ) do
      {:ok, encoded_token} =
        Auth.create_service_account_token(
          socket.assigns.provider,
          identity,
          socket.assigns.subject
        )

      {:noreply, assign(socket, encoded_token: encoded_token)}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp map_expires_at(attrs) do
    Map.update(attrs, "provider_virtual_state", %{}, fn virtual_state ->
      Map.update(virtual_state, "expires_at", nil, fn
        nil -> nil
        "" -> ""
        value -> "#{value}T00:00:00.000000Z"
      end)
    end)
  end
end
