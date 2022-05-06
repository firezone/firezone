defmodule FzHttp.Mailer do
  @moduledoc """
  Outbound Email Sender.
  """
  use Swoosh.Mailer, otp_app: :fz_http

  alias Swoosh.Email

  def default_email do
    Email.new()
    |> Email.from(Application.fetch_env!(:fz_http, FzHttp.Mailer)[:from_email])
  end
end
