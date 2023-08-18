defmodule Web.Actors.NewToken do
  use Web, :live_view
  alias Domain.Actors
  alias Domain.Auth

  def changeset(attrs \\ %{}) do
    data = %{}
    types = %{name: :string, expires_at: :date}

    Ecto.Changeset.cast({data, types}, attrs, Map.keys(types))
    |> Ecto.Changeset.validate_required([:name, :expires_at])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 255)
    |> Domain.Validator.put_default_value(:name, fn -> "tok-" <> Ecto.UUID.generate() end)
    |> Domain.Validator.validate_date(:expires_at, greater_than: Date.utc_today())
  end

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <- Actors.fetch_actor_by_id(id, socket.assigns.subject) do
      changeset = changeset()
      {:ok, assign(socket, actor: actor, identity: nil, form: to_form(changeset, as: :token))}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"token" => attrs}, socket) do
    changeset =
      changeset(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset, as: :token))}
  end

  def handle_event("submit", %{"token" => attrs}, socket) do
    changeset = changeset(attrs)

    with {:ok, data} <- Ecto.Changeset.apply_action(changeset, :validate),
         {:ok, provider} <- Auth.fetch_active_provider_by_adapter(:token, socket.assigns.subject),
         {:ok, identity} <-
           Auth.create_identity(
             socket.assigns.actor,
             provider,
             data.name,
             %{
               expires_at: data.expires_at
             },
             socket.assigns.subject
           ) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/actors/#{identity.actor_id}")
      {:noreply, assign(socket, identity: identity)}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :token))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        Create Token
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Creating Access Token
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <.form :if={is_nil(@identity)} for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input label="Name" field={@form[:name]} placeholder="Name for this token" required />
            </div>
          </div>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <.input
              label="Expires At"
              type="date"
              min={Date.utc_today()}
              field={@form[:expires_at]}
              placeholder="When the token should auto-expire"
              required
            />
          </div>
          <.submit_button>
            Save
          </.submit_button>
        </.form>

        <div :if={not is_nil(@identity)}>
          <div class="text-xl mb-2">
            Your API token (will be shown only once):
          </div>

          <.code_block id="code-sample-docker" class="w-full rounded-lg" phx-no-format>
            <%= @identity.provider_virtual_state.secret %>
          </.code_block>
        </div>
      </div>
    </section>
    """
  end
end
