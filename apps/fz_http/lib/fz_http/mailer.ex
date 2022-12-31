defmodule FzHttpWeb.Mailer do
  @moduledoc """
  Outbound Email Sender.
  """

  use Swoosh.Mailer, otp_app: :fz_http

  alias Swoosh.{Adapters, Email}

  @provider_mapping %{
    "smtp" => Adapters.SMTP,
    "mailgun" => Adapters.Mailgun,
    "mandrill" => Adapters.Mandrill,
    "sendgrid" => Adapters.Sendgrid,
    "post_mark" => Adapters.Postmark,
    "sendmail" => Adapters.Sendmail
  }

  def default_email do
    Email.new()
    |> Email.from(FzHttp.Config.fetch_env!(:fz_http, FzHttpWeb.Mailer)[:from_email])
  end

  def configs_for(provider) do
    adapter = Map.fetch!(@provider_mapping, provider)

    mailer_configs =
      System.fetch_env!("OUTBOUND_EMAIL_CONFIGS")
      |> Jason.decode!()
      |> Map.fetch!(provider)
      |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)

    [adapter: adapter] ++ mailer_configs
  end
end
