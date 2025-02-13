defmodule Web.Settings.Account.Edit do
  use Web, :live_view
  alias Domain.Accounts

  def mount(_params, _session, socket) do
    changeset = Accounts.change_account(socket.assigns.account)

    socket =
      assign(socket,
        page_title: "Edit Account",
        form: to_form(changeset)
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/account"}>
        Account Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/account/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Account {@form.data.name}
      </:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input label="Name" field={@form[:name]} placeholder="Account Name" required />
              </div>
            </div>
            <.submit_button>
              Save
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"account" => attrs}, socket) do
    changeset =
      Accounts.change_account(socket.assigns.account, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"account" => attrs}, socket) do
    with {:ok, _account} <-
           Accounts.update_account(socket.assigns.account, attrs, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/account")}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
