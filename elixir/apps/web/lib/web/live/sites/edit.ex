defmodule Web.Sites.Edit do
  use Web, :live_view
  alias Domain.Gateways
  alias __MODULE__.DB

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- DB.fetch_group_by_id(id, socket.assigns.subject) do
      changeset = change_group(group)

      socket =
        assign(socket,
          page_title: "Edit #{group.name}",
          group: group,
          form: to_form(changeset)
        )

      {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        {@group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/edit"}>Edit</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>Edit Site: <code>{@group.name}</code></:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.input label="Name" field={@form[:name]} placeholder="Name of this Site" required />
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

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      change_group(socket.assigns.group, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    changeset = update_changeset(socket.assigns.group, attrs, socket.assigns.subject)
    
    with {:ok, group} <- DB.update_group(changeset, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "Site #{group.name} updated successfully")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{group}")

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp change_group(group, attrs \\ %{}) do
    import Ecto.Changeset
    
    group
    |> Domain.Repo.preload(:account)
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Domain.Gateways.Group.changeset()
  end

  defp update_changeset(group, attrs, subject) do
    import Ecto.Changeset
    
    group
    |> Domain.Repo.preload(:account)
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Domain.Gateways.Group.changeset()
    |> put_change(:updated_by_identity_id, subject.identity.id)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Repo}
    alias Domain.Gateways.Group

    def fetch_group_by_id(id, subject) do
      result =
        from(g in Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    end

    def update_group(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.update()
    end
  end
end
