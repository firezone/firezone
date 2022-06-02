defmodule FzHttpWeb.MFA.RegisterStepsComponent do
  @moduledoc """
  MFA registration steps
  """
  use Phoenix.Component

  import FzHttpWeb.ErrorHelpers

  def render_step(assigns) do
    case assigns[:step] do
      :pick_type ->
        pick_type(assigns)

      :register ->
        register(assigns)

      :verify ->
        verify(assigns)

      :save ->
        save(assigns)
    end
  end

  def pick_type(assigns) do
    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next">
      <h4>Choose authenticator type</h4>
      <hr>

      <div class="control">
        <div>
          <label class="radio">
            <input type="radio" name="type" value="totp" checked>
            Time-Based One-Time Password
          </label>
        </div>
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
      </div>
    </form>
    """
  end

  def register(assigns) do
    secret = NimbleTOTP.secret()

    assigns =
      Map.merge(
        assigns,
        %{
          secret: secret,
          secret_base64_encoded: Base.encode64(secret),
          uri: NimbleTOTP.otpauth_uri("Firezone:test@test.com", secret, issuer: "Firezone")
        }
      )

    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next">
      <h4>Register Authenticator</h4>
      <hr>

      <input value={@secret_base64_encoded} type="hidden" name="secret" />

      <div class="has-text-centered">
        <canvas data-qrdata={@uri} id="register-totp" phx-hook="RenderQR" />
      </div>

      <div class="field is-horizontal">
        <div class="field-label is-normal">
          <label class="label">Name</label>
        </div>
        <div class="field-body">
          <div class="field">
            <p class="control">
              <input class="input" type="text"
                  name="name"
                  placeholder="Name"
                  value="My Authenticator"
                  required />
            </p>
          </div>
        </div>
      </div>
    </form>
    """
  end

  def verify(assigns) do
    ~H"""
    <form id="mfa-method-form" phx-target={@parent} phx-submit="next">
      <h4>Verify Code</h4>
      <hr>

      <div class="field is-horizontal">
        <div class="field-label is-normal">
          <label class="label">Code</label>
        </div>
        <div class="field-body">
          <div class="field">
            <p class="control">
              <input class={"input #{input_error_class(@changeset, :code)}"} type="text"
                  name="code"
                  placeholder="123456"
                  required />
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
      Save
    </form>
    """
  end
end
