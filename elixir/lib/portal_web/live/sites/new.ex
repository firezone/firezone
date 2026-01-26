defmodule PortalWeb.Sites.New do
  use PortalWeb, :live_view
  alias Portal.Billing
  alias __MODULE__.Database
  import Ecto.Changeset

  def mount(_params, _session, socket) do
    changeset = new_site()
    socket = assign(socket, form: to_form(changeset), page_title: "New Site")
    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name"
                  field={@form[:name]}
                  placeholder="Enter a name for this Site"
                  phx-debounce="300"
                  required
                />
              </div>
            </div>
            <.submit_button>
              Create
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"site" => attrs}, socket) do
    changeset =
      new_site(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"site" => attrs}, socket) do
    attrs = Map.put(attrs, "tokens", [%{}])

    with true <- Billing.can_create_sites?(socket.assigns.subject.account),
         changeset = create_changeset(socket.assigns.subject.account, attrs),
         {:ok, site} <- Database.create_site(changeset, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "Site #{site.name} created successfully")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{site}")

      {:noreply, socket}
    else
      false ->
        changeset =
          new_site(attrs)
          |> Map.put(:action, :insert)

        socket =
          socket
          |> put_flash(
            :error,
            "You have reached the maximum number of sites allowed by your subscription plan."
          )
          |> assign(form: to_form(changeset))

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp new_site(attrs \\ %{}) do
    change_site(%Portal.Site{}, attrs)
  end

  defp change_site(site, attrs) do
    site
    |> cast(attrs, [:name])
  end

  defp create_changeset(account, attrs) do
    %Portal.Site{account_id: account.id}
    |> cast(attrs, [:name])
  end

  defmodule Database do
    alias Portal.Authorization

    def create_site(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Portal.Repo.insert(changeset)
      end)
    end
  end
end
