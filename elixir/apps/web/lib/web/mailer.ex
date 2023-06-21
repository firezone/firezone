defmodule Web.Mailer do
  use Swoosh.Mailer, otp_app: :web
  alias Swoosh.Email

  defp render_template(view, template, format, assigns) do
    heex = apply(view, String.to_existing_atom("#{template}_#{format}"), [assigns])
    assigns = Keyword.merge(assigns, inner_content: heex)
    Phoenix.Template.render_to_string(view, "#{template}_#{format}", "html", assigns)
  end

  def render_body(%Swoosh.Email{} = email, view, template, assigns) do
    assigns = assigns ++ [email: email]

    email
    |> Email.html_body(render_template(view, template, "html", assigns))
    |> Email.text_body(render_template(view, template, "text", assigns))
  end

  def active? do
    mailer_config = Domain.Config.fetch_env!(:web, Web.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      Domain.Config.fetch_env!(:web, Web.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from(from_email)
  end
end
