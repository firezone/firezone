defmodule PortalWeb.Sites.Edit do
  use Web, :live_view
  alias __MODULE__.DB

  def mount(%{"id" => id}, _session, socket) do
    site = DB.get_site!(id, socket.assigns.subject)
    changeset = change_site(site)

    socket =
      assign(socket,
        page_title: "Edit #{site.name}",
        site: site,
        form: to_form(changeset)
      )

    {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}"}>
        {@site.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>Edit Site: <code>{@site.name}</code></:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.input
                label="Name"
                field={@form[:name]}
                placeholder="Name of this Site"
                phx-debounce="300"
                required
              />
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

  def handle_event("change", %{"site" => attrs}, socket) do
    changeset =
      change_site(socket.assigns.site, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"site" => attrs}, socket) do
    changeset = update_changeset(socket.assigns.site, attrs, socket.assigns.subject)

    with {:ok, site} <- DB.update_site(changeset, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "Site #{site.name} updated successfully")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{site}")

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp change_site(site, attrs \\ %{}) do
    import Ecto.Changeset

    site
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Portal.Site.changeset()
  end

  defp update_changeset(site, attrs, _subject) do
    import Ecto.Changeset

    site
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Portal.Site.changeset()
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe

    def get_site!(id, subject) do
      from(s in Portal.Site, as: :site)
      |> where([site: s], s.id == ^id)
      |> preload(:account)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update_site(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end
  end
end
