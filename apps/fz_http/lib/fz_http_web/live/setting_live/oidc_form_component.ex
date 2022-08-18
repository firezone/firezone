defmodule FzHttpWeb.SettingLive.OIDCFormComponent do
  @moduledoc """
  Form for OIDC configs
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Conf

  def render(assigns) do
    ~H"""
    <div>
    <.form let={f} for={@changeset} autocomplete="off" id="oidc-form" phx-target={@myself} phx-submit="save">
      <div class="field">
        <%= label f, :id, "Config ID", class: "label" %>

        <div class="control">
          <%= text_input f, :id,
              class: "input #{input_error_class(f, :id)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :id %>
        </p>
      </div>

      <div class="field">
        <%= label f, :label, class: "label" %>

        <div class="control">
          <%= text_input f, :label,
              class: "input #{input_error_class(f, :label)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :label %>
        </p>
      </div>

      <div class="field">
        <%= label f, :scope, class: "label" %>

        <div class="control">
          <%= text_input f, :scope,
              placeholder: "openid email profile",
              class: "input #{input_error_class(f, :scope)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :scope %>
        </p>
      </div>

      <div class="field">
        <%= label f, :response_type, class: "label" %>

        <div class="control">
          <%= text_input f, :response_type,
              disabled: true,
              class: "input #{input_error_class(f, :response_type)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :response_type %>
        </p>
      </div>

      <div class="field">
        <%= label f, :client_id, "Client ID", class: "label" %>

        <div class="control">
          <%= text_input f, :client_id,
              class: "input #{input_error_class(f, :client_id)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :client_id %>
        </p>
      </div>

      <div class="field">
        <%= label f, :client_secret, class: "label" %>

        <div class="control">
          <%= text_input f, :client_secret,
              class: "input #{input_error_class(f, :client_secret)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :client_secret %>
        </p>
      </div>

      <div class="field">
        <%= label f, :discovery_document_uri, "Discovery Document URI", class: "label" %>

        <div class="control">
          <%= text_input f, :discovery_document_uri,
              placeholder: "https://accounts.google.com/.well-known/openid-configuration",
              class: "input #{input_error_class(f, :discovery_document_uri)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :discovery_document_uri %>
        </p>
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
          |> Conf.update_configuration()

        _ ->
          {:error, changeset}
      end

    case update do
      {:ok, _config} ->
        :ok = Supervisor.terminate_child(FzHttp.Supervisor, FzHttp.OIDC.StartProxy)
        {:ok, _pid} = Supervisor.restart_child(FzHttp.Supervisor, FzHttp.OIDC.StartProxy)

        {:noreply,
         socket
         |> put_flash(:info, "Updated successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
