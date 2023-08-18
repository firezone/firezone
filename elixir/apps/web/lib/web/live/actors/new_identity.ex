defmodule Web.Actors.NewIdentity do
  use Web, :live_view
  alias Domain.{Auth, Actors}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: [:memberships]),
         {:ok, providers} <- Auth.list_active_providers_for_account(socket.assigns.account) do
      providers =
        Enum.filter(providers, fn provider ->
          manual_provisioner_enabled? =
            Auth.fetch_provider_capabilities!(provider)
            |> Keyword.fetch!(:provisioners)
            |> Enum.member?(:manual)

          provider.adapter != :token and manual_provisioner_enabled?
        end)

      provider = List.first(providers)

      changeset = Auth.new_identity(provider)

      socket =
        assign(socket,
          providers: providers,
          actor: actor,
          provider: provider,
          form: to_form(changeset)
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"identity" => attrs}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == attrs["provider_id"]))
    changeset = Auth.new_identity(provider, attrs)
    {:noreply, assign(socket, form: to_form(changeset), provider: provider)}
  end

  def handle_event("submit", %{"identity" => attrs}, socket) do
    {provider_identifier, attrs} = Map.pop(attrs, "provider_identifier")

    with {:ok, _identity} <-
           Auth.create_identity(
             socket.assigns.actor,
             socket.assigns.provider,
             provider_identifier,
             attrs,
             socket.assigns.subject
           ) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/actors/#{socket.assigns.actor}")
      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}/edit"}>
        Add Identity
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Creating an Actor Identity
      </:title>
    </.header>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Create an Identity</h2>
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                type="select"
                label="Provider"
                field={@form[:provider_id]}
                value={@provider.id}
                options={
                  Enum.map(@providers, fn provider ->
                    {"#{provider.name} (#{Web.Settings.IdentityProviders.Components.adapter_name(provider.adapter)})",
                     provider.id}
                  end)
                }
                placeholder="Provider"
                required
              />
            </div>
            <.provider_form form={@form} provider={@provider} />
          </div>
          <.submit_button>
            Save
          </.submit_button>
        </.form>
      </div>
    </section>
    """
  end

  defp provider_form(%{provider: %{adapter: :email}} = assigns) do
    ~H"""
    <div>
      <.input
        label="Email"
        placeholder="Email"
        field={@form[:provider_identifier]}
        autocomplete="off"
      />
    </div>
    """
  end

  defp provider_form(%{provider: %{adapter: :userpass}} = assigns) do
    ~H"""
    <div>
      <.input
        label="Username"
        placeholder="Username"
        field={@form[:provider_identifier]}
        autocomplete="off"
      />
    </div>
    <div>
      <.input
        type="password"
        label="Password"
        placeholder="Password"
        field={@form[:password]}
        autocomplete="off"
      />
    </div>
    <div>
      <.input
        type="password"
        label="Password Confirmation"
        placeholder="Password Confirmation"
        field={@form[:password_confirmation]}
        autocomplete="off"
      />
    </div>
    """
  end
end
