defmodule FzHttpWeb.MFA.RegisterStepsComponent do
  @moduledoc """
  MFA registration steps
  """
  use Phoenix.Component
  import FzHttpWeb.ErrorHelpers

  def render_step(assigns) do
    apply(__MODULE__, assigns.step, [assigns])
  end

  def pick_type(assigns) do
    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next" phx_change="validate">
      <h4>Choose authenticator type</h4>
      <hr />

      <div class="control">
        <div>
          <label class="radio">
            <input type="radio" name="type" value="totp" id="mfa-method-totp" checked />
            Time-Based One-Time Password
          </label>
        </div>
        <!-- Coming Soon
        <div>
          <label class="radio disabled">
            <input type="radio" name="type" value="native" disabled>
            Native (Windows Hello, iOS Face ID, etc)
          </label>
        </div>
        <div>
          <label class="radio disabled">
            <input type="radio" name="type" value="portable" disabled>
            Portable (YubiKey-like products)
          </label>
        </div>
        -->
      </div>
    </form>
    """
  end

  def register(assigns) do
    otpauth_uri =
      NimbleTOTP.otpauth_uri("Firezone:#{assigns.user.email}", assigns.secret, issuer: "Firezone")

    assigns =
      assigns
      |> Map.put(:uri, otpauth_uri)
      |> Map.put(:secret_base32_encoded, Base.encode32(assigns.secret))

    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next" phx_change="validate">
      <h4>Register Authenticator</h4>
      <hr />

      <div class="has-text-centered">
        <canvas data-qrdata={@uri} id="register-totp" phx-hook="RenderQR" />

        <pre
          class="mb-4"
          id="copy-totp-key"
          phx-hook="ClipboardCopy"
          data-clipboard={@secret_base32_encoded}
        ><code><%= format_key(@secret_base32_encoded) %></code></pre>
      </div>

      <div class="field is-horizontal">
        <div class="field-label is-normal">
          <label class="label">Name</label>
        </div>
        <div class="field-body">
          <div class="field">
            <p class="control">
              <input
                class={"input #{input_error_class(@changeset, :name)}"}
                type="text"
                name="name"
                value={Map.get(@changeset.changes, :name, "My Authenticator")}
                placeholder="name"
                required
              />
            </p>
            <p class="help is-danger">
              <%= error_tag(@changeset, :name) %>
            </p>
          </div>
        </div>
      </div>
    </form>
    """
  end

  def verify(assigns) do
    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next" phx_change="validate">
      <h4>Verify Code</h4>
      <hr />

      <div class="field is-horizontal">
        <div class="field-label is-normal">
          <label class="label">Code</label>
        </div>
        <div class="field-body">
          <div class="field">
            <p class="control">
              <input
                class={"input #{input_error_class(@changeset, :code)}"}
                type="text"
                name="code"
                placeholder="123456"
                required
              />
            </p>
            <p class="help is-danger">
              <%= error_tag(@changeset, :code) %>
            </p>
          </div>
        </div>
      </div>
    </form>
    """
  end

  def save(assigns) do
    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="save">
      Confirm to save this Authentication method.
      <%= if !@changeset.valid? do %>
        <p class="help is-danger">
          Something went wrong. Try saving again or starting over.
        </p>
      <% end %>
    </form>
    """
  end

  defp format_key(string) do
    string
    |> String.split("", trim: true)
    |> Enum.chunk_every(4)
    |> Enum.intersperse(" ")
    |> Enum.join("")
  end
end
