defmodule Web.Actors.Edit do
  use Web, :live_view

  alias Domain.Actors

  def mount(%{"id" => id} = _params, _session, socket) do
    {:ok, actor} = Actors.fetch_actor_by_id(id, socket.assigns.subject)

    {:ok, assign(socket, actor: actor)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}"}>
        <%= @actor.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor.id}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Editing User: <code><%= @actor.name %></code>
      </:title>
    </.header>
    <!-- Update User -->
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Edit User Details</h2>
        <form action="#">
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.label for="first-name">
                Name
              </.label>
              <.input type="text" name="name" id="name" value={@actor.name} required="" />
            </div>
            <div>
              <.label for="email">
                Email
              </.label>
              <.input
                aria-describedby="email-explanation"
                type="email"
                name="email"
                id="email"
                value="TODO: Email here"
              />
              <p id="email-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                We'll send a confirmation email to both the current email address and the updated one to confirm the change.
              </p>
            </div>
            <div>
              <.label for="confirm-email">
                Confirm email
              </.label>
              <.input type="email" name="confirm-email" id="confirm-email" value="TODO" />
            </div>
            <div>
              <.label for="user-role">
                Role
              </.label>
              <.input
                type="select"
                id="user-role"
                name="user-role"
                options={[
                  "End User": :account_user,
                  Admin: :account_admin_user,
                  "Service Account": :service_account
                ]}
                value={@actor.type}
              />
              <p id="role-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select Admin to make this user an administrator of your organization.
              </p>
            </div>
            <div>
              <.label for="user-groups">
                Groups
              </.label>
              <.input
                type="select"
                multiple={true}
                name="user-groups"
                id="user-groups"
                options={["TODO: Devops", "TODO: Engineering", "TODO: Accounting"]}
                value=""
              />

              <p id="groups-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Select one or more groups to allow this user access to resources.
              </p>
            </div>
          </div>
          <div class="flex items-center space-x-4">
            <.button type="submit">
              Save
            </.button>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
