defmodule Web.Sites.New do
  use Web, :live_view
  alias Domain.{Gateways, Billing}
  alias __MODULE__.DB

  def mount(_params, _session, socket) do
    changeset = new_group()
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
        <.flash kind={:error} flash={@flash} />
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name"
                  field={@form[:name]}
                  placeholder="Enter a name for this Site"
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

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      new_group(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    attrs = Map.put(attrs, "tokens", [%{}])

    with true <- Billing.can_create_gateway_groups?(socket.assigns.subject.account),
         changeset = create_changeset(socket.assigns.subject.account, attrs, socket.assigns.subject),
         {:ok, group} <- DB.create_group(changeset, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "Site #{group.name} created successfully")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{group}")

      {:noreply, socket}
    else
      false ->
        changeset =
          new_group(attrs)
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
  
  defp new_group(attrs \\ %{}) do
    change_group(%Domain.Gateways.Group{}, attrs)
  end
  
  defp change_group(group, attrs \\ %{}) do
    import Ecto.Changeset
    
    group
    |> Domain.Repo.preload(:account)
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Domain.Gateways.Group.changeset()
  end
  
  defp create_changeset(account, attrs, subject) do
    import Ecto.Changeset
    
    %Domain.Gateways.Group{}
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> Domain.Gateways.Group.changeset()
    |> put_change(:account_id, account.id)
    |> put_change(:managed_by, :account)
    |> put_change(:created_by_identity_id, subject.identity && subject.identity.id)
    |> cast_assoc(:tokens,
      required: false,
      with: &Domain.Tokens.Token.Changeset.create_gateway_group_token(&1, &2, subject)
    )
  end
  
  defmodule DB do
    alias Domain.{Safe}
    
    def create_group(changeset, subject) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end
  end
end
