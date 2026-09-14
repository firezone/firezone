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

  def posture_provider_error_email(provider, recipients) do
    error_email(provider, recipients,
      subject: "Posture Provider Error - #{provider.name}",
      settings_url: url(~p"/#{provider.account}/settings/device_posture"),
      noun: "posture provider",
      record_label: "Provider",
      details_heading: "Posture Provider Details",
      settings_link_text: "device posture settings",
      settings_action: "to verify the provider again and enable syncing.",
      details_rows: provider_details_rows(provider),
      remediation: provider_remediation(provider)
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

  defp provider_details_rows(%Portal.Intune.PostureProvider{} = provider),
    do: [{"Tenant ID", provider.tenant_id}]

  defp provider_details_rows(%Portal.Iru.PostureProvider{} = provider),
    do: [{"Subdomain", provider.subdomain}, {"Region", String.upcase(to_string(provider.region))}]

  defp provider_details_rows(%Portal.Defender.PostureProvider{} = provider),
    do: [{"Tenant ID", provider.tenant_id}]

  defp provider_details_rows(%Portal.Santa.PostureProvider{} = provider),
    do: [{"Workshop URL", provider.api_url}]

  defp provider_details_rows(%Portal.SentinelOne.PostureProvider{} = provider),
    do: [{"Management URL", provider.management_url}]

  defp provider_remediation(%Portal.Intune.PostureProvider{}),
    do: "Please verify the Firezone app registration still has admin consent in Microsoft Entra."

  defp provider_remediation(%Portal.Iru.PostureProvider{}),
    do: "Please verify the Iru API token is still valid and can read devices."

  defp provider_remediation(%Portal.Defender.PostureProvider{}),
    do: "Please verify the Firezone app registration still has admin consent in Microsoft Entra."

  defp provider_remediation(%Portal.Santa.PostureProvider{}),
    do: "Please verify the Workshop API key is still valid and can read hosts."

  defp provider_remediation(%Portal.SentinelOne.PostureProvider{}),
    do: "Please verify the SentinelOne API token is still valid and can view endpoints."
end
