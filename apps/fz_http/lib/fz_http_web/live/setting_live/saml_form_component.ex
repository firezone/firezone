defmodule FzHttpWeb.SettingLive.SAMLFormComponent do
  @moduledoc """
  Form for SAML configs
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Configurations, as: Conf

  def render(assigns) do
    ~H"""
    <div>
    <.form let={f} for={@changeset} autocomplete="off" id="saml-form" phx-target={@myself} phx-submit="save">
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
        <%= label f, :metadata, class: "label" %>

        <div class="control">
          <%= textarea f, :metadata,
              rows: 8,
              class: "textarea #{input_error_class(f, :metadata)}" %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :metadata %>
        </p>
      </div>

      <div class="field">
        <%= label f, :auto_create_users, class: "label" %>

        <div class="control">
          <%= checkbox f, :auto_create_users %>
        </div>
        <p class="help is-danger">
          <%= error_tag f, :auto_create_users %>
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
      |> FzHttp.Conf.SAMLConfig.changeset()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  def handle_event("save", %{"saml_config" => params}, socket) do
    changeset =
      params
      |> FzHttp.Conf.SAMLConfig.changeset()
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
              saml_identity_providers:
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
      {:ok, config} ->
        Application.fetch_env!(:samly, Samly.Provider)
        |> FzHttp.SAML.StartProxy.set_identity_providers(config.saml_identity_providers)
        |> FzHttp.SAML.StartProxy.refresh()

        {:noreply,
         socket
         |> put_flash(:info, "Updated successfully.")
         |> redirect(to: socket.assigns.return_to)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
