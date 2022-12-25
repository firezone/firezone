defmodule FzHttpWeb.SettingLive.OIDCFormComponent do
  @moduledoc """
  Form for OIDC configs
  """
  use FzHttpWeb, :live_component

  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@changeset}
        autocomplete="off"
        id="oidc-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <div class="field">
          <%= label(f, :id, "Config ID", class: "label") %>

          <div class="control">
            <%= text_input(f, :id, class: "input #{input_error_class(f, :id)}") %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :id) %>
          </p>
          <p class="help">
            A unique ID that will be used to generate login URLs for this provider.
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :label, class: "label") %>

          <div class="control">
            <%= text_input(f, :label, class: "input #{input_error_class(f, :label)}") %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :label) %>
          </p>
          <p class="help">
            Text to display on the Login button.
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :scope, class: "label") %>

          <div class="control">
            <%= text_input(f, :scope,
              placeholder: "openid email profile",
              class: "input #{input_error_class(f, :scope)}"
            ) %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :scope) %>
          </p>
          <p class="help">
            Space-delimited list of OpenID scopes.
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :response_type, class: "label") %>

          <div class="control">
            <%= text_input(f, :response_type,
              disabled: true,
              class: "input #{input_error_class(f, :response_type)}"
            ) %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :response_type) %>
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :client_id, "Client ID", class: "label") %>

          <div class="control">
            <%= text_input(f, :client_id, class: "input #{input_error_class(f, :client_id)}") %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :client_id) %>
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :client_secret, class: "label") %>

          <div class="control">
            <%= text_input(f, :client_secret, class: "input #{input_error_class(f, :client_secret)}") %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :client_secret) %>
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :discovery_document_uri, "Discovery Document URI", class: "label") %>

          <div class="control">
            <%= text_input(f, :discovery_document_uri,
              placeholder: "https://accounts.google.com/.well-known/openid-configuration",
              class: "input #{input_error_class(f, :discovery_document_uri)}"
            ) %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :discovery_document_uri) %>
          </p>
        </div>

        <hr />

        <div class="field">
          <%= label(f, :redirect_uri, "Redirect URI", class: "label") %>

          <div class="control">
            <%= text_input(f, :redirect_uri,
              placeholder: "#{@external_url}/auth/oidc/#{@provider_id || "{CONFIG_ID}"}/callback/",
              class: "input #{input_error_class(f, :redirect_uri)}"
            ) %>
          </div>
          <p class="help is-danger">
            <%= error_tag(f, :redirect_uri) %>
          </p>
          <p class="help">
            Optionally override the Redirect URI. Must match the redirect URI set in your IdP.
            In most cases you shouldn't change this.
          </p>
        </div>

        <hr />

        <div class="field">
          <strong>Auto-create users</strong>

          <div class="level">
            <div class="level-left">
              <p class="help">Automatically create users when signing in for the first time.</p>
              <p class="help is-danger">
                <%= error_tag(f, :auto_create_users) %>
              </p>
            </div>
            <div class="level-right">
              <%= label f, :auto_create_users, class: "switch is-medium" do %>
                <%= checkbox(f, :auto_create_users) %>
                <span class="check"></span>
              <% end %>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  def update(assigns, socket) do
    changeset =
      assigns.providers
      |> Map.get(assigns.provider_id, %{})
      |> Map.put("id", assigns.provider_id)
      |> FzHttp.Conf.OIDCConfig.changeset()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:external_url, FzHttp.Config.fetch_env!(:fz_http, :external_url))
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"oidc_config" => params}, socket) do
    changeset =
      params
      |> FzHttp.Conf.OIDCConfig.changeset()
      |> Map.put(:action, :validate)

    update =
      case changeset do
        %{valid?: true} ->
          changeset
          |> Ecto.Changeset.apply_changes()
          |> Map.from_struct()
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> then(fn data ->
            {id, data} = Map.pop(data, "id")

            %{
              openid_connect_providers:
                socket.assigns.providers
                |> Map.delete(socket.assigns.provider_id)
                |> Map.put(id, data)
            }
          end)
          |> FzHttp.Configurations.update_configuration()

        _ ->
          {:error, changeset}
      end

    case update do
      {:ok, _config} ->
        {:noreply,
         socket
         |> put_flash(:info, "Updated successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
