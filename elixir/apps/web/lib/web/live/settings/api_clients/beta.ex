defmodule Web.Settings.ApiClients.Beta do
  use Web, :live_view

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "API Clients")

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/beta"}>Beta</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>
      <:help>
        API Clients are used to manage Firezone configuration through a REST API. See the
        <a class={link_style()} href="https://firezone.dev/kb/reference/rest-api">REST API docs</a>
        for more info.
      </:help>
      <:content>
        <div class="max-w-2xl px-4 py-2 mx-auto">
          <div class="text-lg text-center">
            The Firezone REST API is currently in closed beta.  You may request access by emailing
            <.link
              class={link_style()}
              href={
                mailto_support(@account, @subject, "REST API Closed Beta Request: #{@account.name}")
              }
            >
              support@firezone.dev
            </.link>
            with the following message template.
          </div>
          <div class="my-4">
            Subject: <.code_block
              id="msg_subject"
              class="w-full text-xs whitespace-pre-line"
              phx-no-format
              phx-update="ignore"
            >REST API Closed Beta Request: <%= "#{@account.name}" %></.code_block>
          </div>

          <div class="my-4">
            Body: <.code_block
              id="msg_body"
              class="w-full text-xs whitespace-pre-line"
              phx-no-format
              phx-update="ignore"
            ><%= email_body(@account, @subject) %></.code_block>
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  defp email_body(account, subject) do
    """
    Account Name: #{account.name}
    Account Slug: #{account.slug}
    Account ID: #{account.id}
    Actor ID: #{subject.actor.id}
    """
  end
end
