defmodule Web.Actors.NewUser do
  use Web, :live_view
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    with {:ok, groups} <- Actors.list_groups(socket.assigns.subject),
         {:ok, providers} <- Auth.list_active_providers_for_account(socket.assigns.account) do
      changeset = Actors.new_actor()

      providers =
        Enum.filter(providers, fn provider ->
          manual_provisioner_enabled? =
            Auth.fetch_provider_capabilities!(provider)
            |> Keyword.fetch!(:provisioners)
            |> Enum.member?(:manual)

          provider.adapter != :token and manual_provisioner_enabled?
        end)

      socket =
        assign(socket,
          providers: providers,
          groups: groups,
          provider: List.first(providers),
          form: to_form(changeset)
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == attrs["provider_id"]))

    changeset =
      attrs
      |> map_memberships_attr()
      |> Actors.new_actor()
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset), provider: provider)}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    attrs = map_memberships_attr(attrs)
    {provider_identifier, attrs} = Map.pop(attrs, "provider_identifier")
    {provider_attrs, attrs} = Map.split(attrs, ["password", "password_confirmation"])
    attrs = Map.put(attrs, "provider", provider_attrs)

    with {:ok, actor} <-
           Actors.create_actor(
             socket.assigns.provider,
             provider_identifier,
             attrs,
             socket.assigns.subject
           ) do
      socket = redirect(socket, to: ~p"/#{socket.assigns.account}/actors/#{actor}")
      {:noreply, socket}
    else
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
    <!-- Update User -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Create a User</h2>
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input label="Name" field={@form[:name]} placeholder="Full Name" required />
            </div>
            <div :if={
              Domain.Auth.has_permission?(@subject, Actors.Authorizer.manage_actors_permission())
            }>
              <.input
                type="select"
                label="Role"
                field={@form[:type]}
                options={[
                  {"User", :account_user},
                  {"Admin", :account_admin_user}
                ]}
                placeholder="Role"
                required
              />
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
                type="select"
                label="Provider"
                field={@form[:provider_id]}
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
            <.provider_form :if={@provider} form={@form} provider={@provider} />
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
