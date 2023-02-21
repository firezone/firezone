defmodule FzHttpWeb.SettingLive.ShowApiTokenComponent do
  use FzHttpWeb, :live_component

  alias Phoenix.LiveView.JS
  alias FzHttpWeb.Auth.JSON.Authentication

  def update(assigns, socket) do
    if connected?(socket) do
      {:ok, secret, _claims} = Authentication.fz_encode_and_sign(assigns.api_token, assigns.user)

      {:ok,
       socket
       |> assign(:secret, secret)}
    else
      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <%= if assigns[:secret] do %>
        <div class="level">
          <div class="level-left">
            <h6 class="title is-6">
              API token secret:
            </h6>
          </div>
          <div class="level-right">
            <button
              class="button copy-button"
              phx-click={JS.dispatch("firezone:clipcopy", to: "#api-token-secret")}
            >
              <span class="icon" title="Click to copy API token">
                <i class="mdi mdi-content-copy"></i>
              </span>
            </button>
          </div>
        </div>
        <div class="block">
          <pre class="multiline"><code id="api-token-secret"><%= @secret %></code></pre>
        </div>
        <div class="block">
          <p><strong>Warning!</strong> This token is sensitive data. Store it somewhere safe.</p>
        </div>
        <hr />
        <div class="block">
          <h6 class="title is-6">cURL example:</h6>
          <pre><code id="api-usage-example"><i># List all users</i>
    curl -H 'Content-Type: application/json' \
         -H 'Authorization: Bearer <%= @secret %>' \
         <%= FzHttp.Config.fetch_env!(:fz_http, :external_url) %>/v0/users</code></pre>
        </div>
        <div class="block has-text-right">
          <a href="https://docs.firezone.dev/reference/rest-api?utm_source=product">
            Explore the REST API docs -&gt;
          </a>
        </div>
      <% end %>
    </div>
    """
  end
end
