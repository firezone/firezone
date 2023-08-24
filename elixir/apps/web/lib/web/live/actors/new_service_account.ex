defmodule Web.Actors.NewServiceAccount do
  use Web, :live_view
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    with {:ok, groups} <- Actors.list_groups(socket.assigns.subject) do
      changeset = Actors.new_actor()

      socket =
        assign(socket,
          groups: groups,
          actor: nil,
          form: to_form(changeset)
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    changeset =
      attrs
      |> map_memberships_attr()
      |> Map.put("type", :service_account)
      |> Actors.new_actor()
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs =
      attrs
      |> map_memberships_attr()
      |> Map.put("type", :service_account)
      |> Map.put("provider", %{"expires_at" => attrs["expires_at"] <> "T00:00:00Z"})
      |> Map.put("provider_identifier", "tok-#{Ecto.UUID.generate()}")

    with {:ok, provider} <- Auth.fetch_active_provider_by_adapter(:token, socket.assigns.subject),
         {:ok, actor} <- Actors.create_actor(provider, attrs, socket.assigns.subject) do
      {:noreply, assign(socket, actor: actor)}
    else
      {:error, :not_found} ->
        socket = put_flash(socket, :error, "Please enable Token authorization provider first.")
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp map_memberships_attr(attrs) do
    Map.update(attrs, "memberships", [], fn group_ids ->
      Enum.map(group_ids, fn group_id ->
        %{group_id: group_id}
      end)
    end)
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/new"}>Add</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Creating an Actor
      </:title>
    </.header>
    <section class="bg-white dark:bg-gray-900">
      <div :if={is_nil(@actor)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Create a Service Account</h2>
        <.flash kind={:error} flash={@flash} />
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input label="Name" field={@form[:name]} placeholder="Name" required />
            </div>

            <div>
              <.input
                type="select"
                multiple={true}
                label="Groups"
                field={@form[:memberships]}
                value={Enum.map(@form[:memberships].value || [], & &1.group_id)}
                options={Enum.map(@groups, fn group -> {group.name, group.id} end)}
                placeholder="Groups"
              />
              <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Hold <kbd>Ctrl</kbd>
                (or <kbd>Command</kbd>
                on Mac) to select or unselect multiple groups.
              </p>
            </div>
            <div>
              <.input
                label="Token Expires At"
                type="date"
                field={@form[:expires_at]}
                min={Date.utc_today()}
                value={Date.utc_today() |> Date.add(365) |> Date.to_string()}
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

      <div :if={not is_nil(@actor)} class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <div class="text-xl mb-2">
          Your API token (will be shown only once):
        </div>

        <.code_block id="code-sample-docker" class="w-full rounded-lg" phx-no-format>
            <%= hd(@actor.identities).provider_virtual_state.secret %>
          </.code_block>
      </div>
    </section>
    """
  end
end
