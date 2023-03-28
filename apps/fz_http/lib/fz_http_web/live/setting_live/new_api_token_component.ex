defmodule FzHttpWeb.SettingLive.NewApiTokenComponent do
  @moduledoc """
  Live component to manage creating API Tokens
  """
  use FzHttpWeb, :live_component

  alias FzHttp.ApiTokens

  def render(assigns) do
    ~H"""
    <div>
      <.form
        :let={f}
        for={@changeset}
        autocomplete="off"
        id="api-token-form"
        phx-target={@myself}
        phx-submit="save"
      >
        <%= if @changeset.action do %>
          <div class="notification is-danger">
            <div class="flash-error">
              <%= error_tag(f, :base) %>
            </div>
          </div>
        <% end %>
        <div class="field is-horizontal">
          <div class="field-label is-normal">
            <%= label(f, :expires_in, class: "label") %>
          </div>
          <div class="field-body">
            <div class="field is-expanded">
              <div class="field has-addons">
                <p class="control is-expanded">
                  <%= text_input(f, :expires_in, class: "input #{input_error_class(f, :expires_in)}") %>
                </p>
                <p class="control">
                  <a class="button is-static">
                    days
                  </a>
                </p>
              </div>
            </div>
            <div class="help is-danger">
              <%= error_tag(f, :expires_in) %>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  def handle_event("save", %{"api_token" => attrs}, socket) do
    subject = socket.assigns.subject

    case ApiTokens.create_api_token(attrs, subject) do
      {:ok, api_token} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/settings/account/api_token/#{api_token}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end
end
