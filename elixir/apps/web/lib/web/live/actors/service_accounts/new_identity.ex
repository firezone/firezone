defmodule Web.Actors.ServiceAccounts.NewIdentity do
  use Web, :live_view
  alias Domain.{Auth, Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [:memberships],
             filter: [
               deleted?: false,
               types: ["service_account"]
             ]
           ) do
      changeset = Tokens.Token.Changeset.create(%{})

      socket =
        assign(socket,
          page_title: "New Service Account Token",
          actor: actor,
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
        {@actor.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}>
        Create Token
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div :if={is_nil(@encoded_token)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
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
              Your Service Account token
            </div>
            <div>
              <.code_block id="code-sample-docker" class="w-full mw-1/2 rounded" phx-no-format><%= @encoded_token %></.code_block>
              <p class="mt-2 text-xs text-gray-500">
                Store this in a safe place. <strong>It won't be shown again.</strong>
              </p>
            </div>

            <div class="flex justify-start">
              <.button icon="hero-arrow-uturn-left" navigate={~p"/#{@account}/actors/#{@actor}"}>
                Back to Service Account
              </.button>
            </div>
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
