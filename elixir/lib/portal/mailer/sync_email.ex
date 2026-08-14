defmodule Portal.Mailer.SyncEmail do
  import Swoosh.Email
  import Portal.Mailer
  import Phoenix.Template, only: [embed_templates: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: PortalWeb.Endpoint,
    router: PortalWeb.Router,
    statics: PortalWeb.static_paths()

  embed_templates "sync_email/*.html", suffix: "_html"
  embed_templates "sync_email/*.text", suffix: "_text"

  def sync_error_email(directory, recipients) do
    error_email(directory, recipients,
      subject: "Directory Sync Error - #{directory.name}",
      settings_url: url(~p"/#{directory.account}/settings/directory_sync"),
      noun: "directory",
      record_label: "Directory",
      details_heading: "Directory Details",
      settings_link_text: "directory sync settings",
      settings_action: "to re-verify the directory and enable sync.",
      remediation: "Please verify that all directory information entered into Firezone is correct."
    )
  end

  def device_integration_error_email(integration, recipients) do
    error_email(integration, recipients,
      subject: "Device Integration Error - #{integration.name}",
      settings_url: url(~p"/#{integration.account}/settings/device_posture"),
      noun: "device integration",
      record_label: "Integration",
      details_heading: "Device Integration Details",
      settings_link_text: "device integration settings",
      settings_action: "to re-grant admin consent and enable syncing.",
      details_rows: [{"Tenant ID", integration.tenant_id}],
      remediation:
        "Please verify the Firezone app registration still has admin consent in Microsoft Entra."
    )
  end

  # One template serves every provider whose sync can be disabled by an error;
  # only the nouns, the settings link and the remediation sentence differ.
  defp error_email(record, recipients, opts) do
    default_email()
    |> subject(Keyword.fetch!(opts, :subject))
    |> put_recipients(recipients)
    |> with_account_id(record.account.id)
    |> render_body(__MODULE__, :sync_error,
      account: record.account,
      record: record,
      settings_url: Keyword.fetch!(opts, :settings_url),
      noun: Keyword.fetch!(opts, :noun),
      record_label: Keyword.fetch!(opts, :record_label),
      details_heading: Keyword.fetch!(opts, :details_heading),
      settings_link_text: Keyword.fetch!(opts, :settings_link_text),
      settings_action: Keyword.fetch!(opts, :settings_action),
      details_rows: Keyword.get(opts, :details_rows, []),
      remediation: Keyword.fetch!(opts, :remediation)
    )
  end

  defp put_recipients(email, recipients) when is_list(recipients),
    do: bcc_recipients(email, recipients)

  defp put_recipients(email, recipient), do: to(email, recipient)
end
