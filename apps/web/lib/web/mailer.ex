defmodule Web.Mailer do
  use Swoosh.Mailer, otp_app: :web
  alias Swoosh.Email

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
