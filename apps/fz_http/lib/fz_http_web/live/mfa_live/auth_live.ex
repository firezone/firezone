defmodule FzHttpWeb.MFALive.Auth do
  @moduledoc """
  Handles MFA LiveViews.
  """
  use FzHttpWeb, :live_view

  import FzHttpWeb.ControllerHelpers
  alias FzHttp.MFA

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "MFA")}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"id" => id}, _uri, socket) do
    changeset = id |> MFA.get_method!() |> MFA.change_method()
    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    changeset =
      socket.assigns.current_user
      |> MFA.most_recent_method()
      |> MFA.change_method()

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :auth} = assigns) do
    ~H"""
    <section class="section is-main-section">
      <%= render FzHttpWeb.SharedView, "flash.html", assigns %>
      <h4 class="title is-4"><%= @page_title %></h4>

      <form id="mfa-method-form" phx-submit="verify">
        <h4>Verify Code</h4>
        <hr>

        <div class="field is-horizontal">
          <div class="field-label is-normal">
            <label class="label">Code</label>
          </div>
          <div class="field-body">
            <div class="field">
              <p class="control">
                <input class={"input #{input_error_class(@changeset, :code)}"}
                    type="text" name="code" placeholder="123456" required />
              </p>
            </div>
          </div>
        </div>

        <div class="field">
          <div class="control">
            <div class="level">
              <div class="level-left">
                <%= submit "Verify",
                    phx_disable_with: "verifying...",
                    form: assigns[:form],
                    class: "button is-primary" %>
              </div>
              <div class="level-right">
                <%= live_patch "Other authenticators ->",
                    to: Routes.mfa_auth_path(@socket, :types) %>
              </div>
            </div>
          </div>
        </div>
      </form>
    </section>
    """
  end

  @impl Phoenix.LiveView
  def render(%{live_action: :types} = assigns) do
    assigns = Map.put(assigns, :methods, MFA.list_methods(assigns.current_user))

    ~H"""
    <section class="section is-main-section">
      <%= render FzHttpWeb.SharedView, "flash.html", assigns %>
      <h4 class="title is-4"><%= @page_title %></h4>

      <ul>
        <%= for method <- @methods do %>
        <li>
          <%= live_patch "[#{method.type}] #{method.name} ->",
              to: Routes.mfa_auth_path(@socket, :auth, method.id) %>
        </li>
        <% end %>
      </ul>
    </section>
    """
  end

  @impl Phoenix.LiveView
  def handle_event("verify", %{"code" => code}, socket) do
    case MFA.update_method(socket.assigns.changeset.data, %{code: code}) do
      {:ok, _method} ->
        {:noreply,
         push_redirect(socket,
           to: root_path_for_role(FzHttpWeb.Endpoint, socket.assigns.current_user.role)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
