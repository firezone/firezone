defmodule Portal.Mailer.Notifications do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]
  alias Portal.{Actor, UnsubscribeToken}

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "notifications/*.html", suffix: "_html"
  embed_templates "notifications/*.text", suffix: "_text"

  def outdated_gateway_email(account, gateways, incompatible_client_count, %Actor{} = admin) do
    params = %{devices_order_by: "devices:asc:last_seen_version"}
    outdated_clients_url = url(~p"/#{account}/devices?#{params}")

    default_email()
    |> subject("Firezone Gateway Upgrade Available")
    |> to(admin.email)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :outdated_gateway,
      account: account,
      gateways: gateways,
      outdated_clients_url: outdated_clients_url,
      incompatible_client_count: incompatible_client_count,
      latest_version: Portal.ComponentVersions.gateway_version(),
      unsubscribe_url: unsubscribe_url(admin, :outdated_gateways)
    )
  end

  def limits_exceeded_email(account, warning, recipients) do
    billing_url = url(~p"/#{account}/settings/account")
    plan_type = Portal.Billing.plan_type(account)

    default_email()
    |> subject("Firezone Account Limits Exceeded")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :limits_exceeded,
      account: account,
      warning: warning,
      billing_url: billing_url,
      plan_type: plan_type
    )
  end

  def seats_warning_email(account, level, active_users_count, %Actor{} = admin) do
    billing_url = url(~p"/#{account}/settings/account")
    limit = account.limits.monthly_active_users_count

    heading =
      case level do
        :over -> "You are over your seat limit"
        :at_limit -> "You have reached your seat limit"
        :approaching -> "You are approaching your seat limit"
      end

    default_email()
    |> subject(heading)
    |> reply_to("support@firezone.dev")
    |> to(admin.email)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :seats_warning,
      account: account,
      level: level,
      heading: heading,
      active_users_count: active_users_count,
      seats_limit: limit,
      seats_remaining: max(limit - active_users_count, 0),
      seats_over: max(active_users_count - limit, 0),
      billing_url: billing_url,
      unsubscribe_url: unsubscribe_url(admin, :seat_limit_warnings)
    )
  end

  @doc """
  The monthly product announcement. The HTML and text bodies are written by
  Firezone staff through `Portal.Ops` and placed inside the usual email layout
  as they are, so the HTML is not escaped.
  """
  def product_announcement_email(subject, html_body, text_body, %Actor{} = admin) do
    default_email()
    |> subject(subject)
    |> reply_to("support@firezone.dev")
    |> to(admin.email)
    |> with_account_id(admin.account_id)
    |> render_body(__MODULE__, :product_announcement,
      subject: subject,
      announcement_html: announcement_html(html_body),
      announcement_text: text_body,
      unsubscribe_url: unsubscribe_url(admin, :product_announcements)
    )
  end

  def account_scheduled_for_deletion_email(account, recipients, context) do
    settings_url = url(~p"/#{account}/settings/account")

    default_email()
    |> subject("Firezone Account Scheduled for Deletion")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :account_scheduled_for_deletion,
      account: account,
      settings_url: settings_url,
      remote_ip: redact_ip(context.remote_ip),
      location: format_location(context),
      user_agent: context.user_agent,
      paid_plan: Portal.Billing.paid_plan?(account)
    )
  end

  def account_deletion_aborted_email(account, recipients, context) do
    settings_url = url(~p"/#{account}/settings/account")

    default_email()
    |> subject("Firezone Account Deletion Aborted")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :account_deletion_aborted,
      account: account,
      settings_url: settings_url,
      remote_ip: redact_ip(context.remote_ip),
      location: format_location(context),
      user_agent: context.user_agent
    )
  end

  def account_deletion_reminder_email(account, recipients) do
    settings_url = url(~p"/#{account}/settings/account")

    default_email()
    |> subject("Firezone Account Deletion Reminder")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :account_deletion_reminder,
      account: account,
      settings_url: settings_url,
      paid_plan: Portal.Billing.paid_plan?(account)
    )
  end

  def account_deletion_completed_email(account, recipients) do
    default_email()
    |> subject("Firezone Account Deletion Complete")
    |> put_recipients(recipients)
    |> with_account_id(account.id)
    |> render_body(__MODULE__, :account_deletion_completed, account: account)
  end

  # Staff-authored HTML only, see Portal.Ops.queue_product_announcement/3.
  # sobelow_skip ["XSS.Raw"]
  defp announcement_html(html_body), do: Phoenix.HTML.raw(html_body)

  defp unsubscribe_url(actor, notification) do
    url(~p"/#{actor.account_id}/unsubscribe/#{UnsubscribeToken.sign(actor, notification)}")
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)

  defp redact_ip({a, b, _, _}), do: "#{a}.#{b}.*.*"

  defp redact_ip({a, b, c, d, _, _, _, _}),
    do: "#{hex(a)}:#{hex(b)}:#{hex(c)}:#{hex(d)}:*:*:*:*"

  defp hex(n), do: Integer.to_string(n, 16)

  defp format_location(%{remote_ip_location_city: city, remote_ip_location_region: region}) do
    case [city, region] |> Enum.reject(&is_nil/1) |> Enum.join(", ") do
      "" -> "Unknown"
      location -> location
    end
  end
end
