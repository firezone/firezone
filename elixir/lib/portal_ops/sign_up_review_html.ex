defmodule PortalOps.SignUpReviewHTML do
  use Phoenix.Component

  def show(assigns) do
    ~H"""
    <.page title="Review sign-up">
      <dl>
        <dt>Name</dt>
        <dd>{@review.registration.actor_name}</dd>
        <dt>Email</dt>
        <dd>{@review.registration.email}</dd>
        <dt>Company</dt>
        <dd>{@review.registration.company_name}</dd>
        <dt>Mail servers</dt>
        <dd :for={{host, verdict} <- @review.mail_servers}><code>{host}</code> ({verdict_label(verdict)})</dd>
        <dd :if={@review.mail_servers == []}>None found</dd>
      </dl>

      <.form for={%{}} id="sign-up-review-form" action="/sign_up_review" method="post">
        <input type="hidden" name="token" value={@token} />
        <fieldset :if={@suggested_domains != []}>
          <legend>Mail server domains to add to the list</legend>
          <label :for={domain <- @suggested_domains}>
            <input type="checkbox" name="domains[]" value={domain} checked /> <code>{domain}</code>
            <br />
          </label>
        </fieldset>
        <p :if={@error}><strong>{@error}</strong></p>
        <p>
          <button type="submit" name="decision" value="approve_and_allow">
            Approve and add domains to allowlist
          </button>
          <button type="submit" name="decision" value="approve">Approve only</button>
        </p>
        <p>
          <button type="submit" name="decision" value="deny_and_deny">
            Deny and add domains to denylist
          </button>
          <button type="submit" name="decision" value="deny">Deny only</button>
        </p>
      </.form>
    </.page>
    """
  end

  def approved(assigns) do
    ~H"""
    <.page title="Sign-up approved">
      <p>
        Account {@account.name} is created and the welcome email is sent to {@review.registration.email}.
      </p>
      <p :if={@domains != []}>Added to the allowlist: {Enum.join(@domains, ", ")}</p>
    </.page>
    """
  end

  def denied(assigns) do
    ~H"""
    <.page title="Sign-up denied">
      <p>No account is created for {@review.registration.email}.</p>
      <p :if={@domains != []}>Added to the denylist: {Enum.join(@domains, ", ")}</p>
    </.page>
    """
  end

  def exists(assigns) do
    ~H"""
    <.page title="Already approved">
      <p>{@review.registration.email} already has an account.</p>
    </.page>
    """
  end

  def invalid(assigns) do
    ~H"""
    <.page title="Link not valid">
      <p>This review link is invalid or has expired.</p>
    </.page>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
      </head>
      <body>
        <h1>{@title}</h1>
        {render_slot(@inner_block)}
      </body>
    </html>
    """
  end

  defp verdict_label(:allow), do: "allowed"
  defp verdict_label(:unknown), do: "unknown"
end
