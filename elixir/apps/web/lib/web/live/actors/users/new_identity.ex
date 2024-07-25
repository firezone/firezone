defmodule Web.Actors.Users.NewIdentity do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Auth, Actors}

  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [:memberships],
             filter: [
               deleted?: false,
               types: ["account_user", "account_admin_user"]
             ]
           ) do
      providers =
        Auth.all_active_providers_for_account!(socket.assigns.account)
        |> Enum.filter(fn provider ->
          Auth.fetch_provider_capabilities!(provider)
          |> Keyword.fetch!(:provisioners)
          |> Enum.member?(:manual)
        end)

      provider = List.first(providers)
      changeset = Auth.new_identity(actor, provider)

      socket =
        assign(socket,
          actor: actor,
          providers: providers,
          provider: provider,
          form: to_form(changeset),
          page_title: "New User Identity",
          next_step: Map.get(params, "next_step")
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
      <.breadcrumb path={~p"/#{@account}/actors/users/#{@actor}/new_identity"}>
        Add Identity
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title><%= @page_title %></:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">Identity details</h2>
          <.flash kind={:error} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
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
                <p class="mt-2 text-xs text-gray-500">
                  Select the provider to use for signing in.
                </p>
              </div>
              <.provider_form :if={@provider} form={@form} provider={@provider} />
            </div>
            <.submit_button>
              <%= if @next_step == "edit_groups" do %>
                Next: Select Group Memberships
              <% else %>
                Create Identity
              <% end %>
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"identity" => attrs}, socket) do
    provider = Enum.find(socket.assigns.providers, &(&1.id == attrs["provider_id"]))

    changeset =
      Auth.new_identity(socket.assigns.actor, provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset), provider: provider)}
  end

  def handle_event("submit", %{"identity" => attrs}, socket) do
    with {:ok, identity} <-
           Auth.create_identity(
             socket.assigns.actor,
             socket.assigns.provider,
             attrs,
             socket.assigns.subject
           ) do
      if socket.assigns.provider.adapter == :email do
        Web.Mailer.AuthEmail.new_user_email(
          socket.assigns.account,
          identity,
          socket.assigns.subject
        )
        |> Web.Mailer.deliver()
      end

      socket = push_navigate(socket, to: next_path(socket))

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp next_path(socket) do
    case socket.assigns.next_step do
      "edit_groups" -> ~p"/#{socket.assigns.account}/actors/#{socket.assigns.actor}/edit_groups"
      _ -> ~p"/#{socket.assigns.account}/actors/#{socket.assigns.actor}"
    end
  end
end
