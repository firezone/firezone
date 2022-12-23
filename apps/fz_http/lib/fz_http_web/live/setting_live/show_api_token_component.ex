defmodule FzHttpWeb.SettingLive.ShowApiTokenComponent do
  use FzHttpWeb, :live_component

  alias Phoenix.LiveView.JS
  alias FzHttpWeb.Auth.JSON.Authentication

  def update(assigns, socket) do
    if connected?(socket) do
      api_token = FzHttp.ApiTokens.get_api_token!(assigns.api_token_id)

      claims = %{
        "jti" => assigns.api_token_id,
        "exp" => DateTime.to_unix(api_token.expires_at)
      }

      {:ok, secret, _claims} = Guardian.encode_and_sign(Authentication, assigns.user, claims)

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
            <p>
              Use the token below to authenticate to the Firezone REST API:
            </p>
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
        <hr />
        <div class="block">
          <h5 class="title is-5">cURL Example:</h5>
          <pre><code><i># List all users</i>
    curl -H 'Content-Type: application/json' \
         -H 'Authorization: Bearer <%= @secret %>' \
         https://firezone.company.com/v1/users</code></pre>
        </div>
        <div class="block">
          <a href="https://docs.firezone.dev/reference/rest-api?utm_source=product">
            Explore the REST API docs -&gt;
          </a>
        </div>
      <% end %>
    </div>
    """
  end
end
