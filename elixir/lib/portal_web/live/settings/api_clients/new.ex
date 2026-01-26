defmodule PortalWeb.Settings.ApiClients.New do
  use PortalWeb, :live_view
  import PortalWeb.Settings.ApiClients.Components
  import Ecto.Changeset
  alias Portal.Actor
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    account = socket.assigns.account

    cond do
      not Portal.Account.rest_api_enabled?(account) ->
        {:ok, push_navigate(socket, to: ~p"/#{account}/settings/api_clients/beta")}

      not Portal.Billing.can_create_api_clients?(account) ->
        socket =
          socket
          |> put_flash(
            :error,
            "You have reached the maximum number of API clients allowed for your account."
          )
          |> push_navigate(to: ~p"/#{account}/settings/api_clients")

        {:ok, socket}

      true ->
        changeset = changeset(%{})

        socket =
          assign(socket,
            form: to_form(changeset),
            page_title: "New API Client"
          )

        {:ok, socket, temporary_assigns: [form: %Phoenix.HTML.Form{}]}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <h2 class="mb-4 text-xl text-neutral-900">
            API Client details
          </h2>
          <.flash kind={:error_inline} flash={@flash} />
          <.form for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <.api_client_form form={@form} type={:api_client} subject={@subject} />
            </div>
            <.submit_button>
              Next: Add a token
            </.submit_button>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"actor" => attrs}, socket) do
    changeset =
      attrs
      |> changeset()
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"actor" => attrs}, socket) do
    account = socket.assigns.account

    if Portal.Billing.can_create_api_clients?(account) do
      attrs = Map.put(attrs, "type", :api_client)
      changeset = changeset(attrs)
      changeset = %{changeset | action: nil}
      changeset = Ecto.Changeset.put_change(changeset, :account_id, account.id)

      with {:ok, actor} <- Database.create_api_client(changeset, socket.assigns.subject) do
        socket =
          push_navigate(socket,
            to: ~p"/#{account}/settings/api_clients/#{actor}/new_token"
          )

        {:noreply, socket}
      else
        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      socket =
        socket
        |> put_flash(
          :error,
          "You have reached the maximum number of API clients allowed for your account."
        )
        |> push_navigate(to: ~p"/#{account}/settings/api_clients")

      {:noreply, socket}
    end
  end

  defp changeset(attrs) do
    %Actor{type: :api_client}
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  defmodule Database do
    alias Portal.Authorization

    def create_api_client(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Portal.Repo.insert(changeset)
      end)
    end
  end
end
