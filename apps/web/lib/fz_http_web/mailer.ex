defmodule FzHttpWeb.Mailer do
  @moduledoc """
  Outbound Email Sender.
  """
  use Swoosh.Mailer, otp_app: :fz_http
  alias Swoosh.Email

  def active? do
    mailer_config = FzHttp.Config.fetch_env!(:fz_http, FzHttpWeb.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      FzHttp.Config.fetch_env!(:fz_http, FzHttpWeb.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from(from_email)
  end
end
