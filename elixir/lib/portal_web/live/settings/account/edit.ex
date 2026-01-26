defmodule PortalWeb.Settings.Account.Edit do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    changeset = change_account_name(socket.assigns.account)

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
                <.input
                  label="Name"
                  field={@form[:name]}
                  placeholder="Account Name"
                  phx-debounce="300"
                  required
                />
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

  defp change_account_name(account, attrs \\ %{}) do
    import Ecto.Changeset

    account
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  def handle_event("change", %{"account" => attrs}, socket) do
    changeset =
      change_account_name(socket.assigns.account, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"account" => attrs}, socket) do
    with {:ok, account} <-
           update_account_name(socket.assigns.account, attrs, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "Account #{account.name} updated successfully")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/settings/account")

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_account_name(account, attrs, subject) do
    account
    |> change_account_name(attrs)
    |> Database.update(subject)
  end

  defmodule Database do
    alias Portal.Safe

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
