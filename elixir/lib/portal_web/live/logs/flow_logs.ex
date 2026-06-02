defmodule PortalWeb.Logs.FlowLogs do
  use PortalWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Flow Logs")}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.page_header>
        <:icon>
          <.icon name="ri-file-list-3-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Logs</:title>
        <:description>
          Audit logs related to configuration changes and network activity in your organization.
        </:description>
        <:action>
          <.docs_action path="/administer/logs" />
        </:action>
      </.page_header>

      <.logs_nav account={@account} current_path={@current_path} />

      <div class="flex-1 overflow-y-auto p-6">
        <div class="max-w-2xl mx-auto">
          <div class="rounded-lg border border-[var(--border)] bg-[var(--surface)] overflow-hidden">
            <div class="px-6 py-8 flex flex-col items-center text-center gap-4">
              <div class="w-14 h-14 rounded-full border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <.icon name="ri-exchange-line" class="w-7 h-7 text-[var(--brand)]" />
              </div>
              <div>
                <h3 class="text-base font-semibold text-[var(--text-primary)]">
                  Flow Logs in the portal are coming soon!
                </h3>
                <p class="mt-2 text-sm text-[var(--text-secondary)] max-w-md mx-auto">
                  In the meantime, flow logs can be emitted to stdout on your gateways by setting
                  the environment variable below.
                </p>
              </div>

              <div class="w-full mt-2 rounded border border-[var(--border)] bg-[var(--surface-raised)]">
                <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--border)]">
                  <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                    Gateway environment
                  </span>
                  <.icon name="ri-terminal-box-line" class="w-3.5 h-3.5 text-[var(--text-tertiary)]" />
                </div>
                <pre class="px-3 py-3 text-left text-xs font-mono text-[var(--text-primary)] overflow-x-auto"><code>FIREZONE_FLOW_LOGS=true</code></pre>
              </div>

              <div class="flex items-start gap-2 text-left rounded border border-[var(--border)] bg-[var(--surface-raised)] px-3 py-2 text-xs text-[var(--text-secondary)] w-full">
                <.icon name="ri-information-line" class="w-4 h-4 shrink-0 mt-0.5 text-[var(--brand)]" />
                <span>
                  Flow logs are written to stdout on the gateway process. Capture them with your
                  log aggregator of choice.
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
