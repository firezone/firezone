defmodule PortalWeb.HomeHTML do
  use PortalWeb, :html

  def home(assigns) do
    ~H"""
    <.flash kind={:error} flash={@flash} />

    <div :if={!@show_account_chooser}>
      <.get_started params={@params} />
    </div>

    <div :if={@show_account_chooser}>
      <.account_chooser
        accounts={@accounts}
        params={@params}
        show_account_chooser={@show_account_chooser}
      />
    </div>
    """
  end

  defp get_started(assigns) do
    ~H"""
    <div class="mb-10 text-center">
      <div class="flex lg:hidden items-center justify-center gap-2 mb-8">
        <img src="/images/logo.svg" class="w-6 h-6" alt="Firezone Logo" />
        <span class="text-sm font-semibold text-[var(--text-primary)]">Firezone</span>
      </div>
      <h1 class="text-2xl font-bold text-[var(--text-primary)] tracking-tight">Let's get started!</h1>
      <p class="text-sm text-[var(--text-secondary)] mt-2">Which best describes why you're here?</p>
    </div>

    <div class="space-y-2.5">
      <a
        href={~p"/sign_up"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-[var(--border)] bg-[var(--surface)] hover:border-[var(--brand)] transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-[var(--brand)]/10">
          <svg
            class="w-5 h-5 text-[var(--brand)]"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
            <polyline points="9 22 9 12 15 12 15 22" />
          </svg>
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
            Set up a new organization
          </p>
          <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
            Create an admin account for your team.
          </p>
        </div>
        <svg
          class="w-4 h-4 text-[var(--text-muted)] group-hover:text-[var(--brand)] group-hover:translate-x-0.5 transition-all shrink-0"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M6 3l5 5-5 5" />
        </svg>
      </a>

      <a
        href={~p"/find_account?#{@params}"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-[var(--border)] bg-[var(--surface)] hover:border-[var(--brand)] transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-violet-500/10 dark:bg-violet-400/10">
          <svg
            class="w-5 h-5 text-violet-500 dark:text-violet-400"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
            <circle cx="9" cy="7" r="4" />
            <path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" />
          </svg>
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
            My company uses Firezone
          </p>
          <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
            Find your organization's sign-in page.
          </p>
        </div>
        <svg
          class="w-4 h-4 text-[var(--text-muted)] group-hover:text-[var(--brand)] group-hover:translate-x-0.5 transition-all shrink-0"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M6 3l5 5-5 5" />
        </svg>
      </a>

      <a
        href={~p"/?choose=true&#{@params}"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-[var(--border)] bg-[var(--surface)] hover:border-[var(--brand)] transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-slate-100 dark:bg-slate-800">
          <svg
            class="w-5 h-5 text-slate-500 dark:text-slate-400"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <polyline points="4 17 10 11 4 5" />
            <line x1="12" y1="19" x2="20" y2="19" />
          </svg>
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
            I know what I'm doing
          </p>
          <p class="text-xs text-[var(--text-tertiary)] mt-0.5 leading-relaxed">
            Go straight to account sign-in.
          </p>
        </div>
        <svg
          class="w-4 h-4 text-[var(--text-muted)] group-hover:text-[var(--brand)] group-hover:translate-x-0.5 transition-all shrink-0"
          viewBox="0 0 16 16"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M6 3l5 5-5 5" />
        </svg>
      </a>
    </div>
    """
  end

  defp account_chooser(assigns) do
    ~H"""
    <%!-- Branded header --%>
    <div class="flex items-center gap-3 mb-8">
      <div class="w-10 h-10 rounded bg-[var(--brand)]/10 border border-[var(--brand)]/20 flex items-center justify-center shrink-0 lg:hidden">
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-[var(--text-primary)] tracking-tight">
          Sign in to Firezone
        </h1>
        <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
          Choose your organization to continue.
        </p>
      </div>
    </div>

    <%!-- Recently signed in --%>
    <div :if={@accounts != []}>
      <div class="flex items-center gap-3 mb-3">
        <div class="flex-1 h-px bg-[var(--border)]"></div>
        <span class="text-xs font-medium text-[var(--text-muted)] uppercase tracking-widest">
          Recently signed in
        </span>
        <div class="flex-1 h-px bg-[var(--border)]"></div>
      </div>
      <div class="flex flex-col gap-2 mb-6">
        <.account_button :for={account <- @accounts} account={account} params={@params} />
      </div>
    </div>

    <%!-- Slug entry card --%>
    <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4">
      <p class="text-xs font-semibold text-[var(--text-secondary)] mb-3">
        Enter your organization's account slug
      </p>
      <.form :let={f} for={%{}} action={~p"/?#{@params}"}>
        <div class="flex gap-2">
          <input
            type="text"
            name={f[:account_id_or_slug].name}
            placeholder="e.g. acme-corp"
            autofocus={@accounts == []}
            required
            class="flex-1 px-3 py-2 text-sm rounded border bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors placeholder:text-[var(--text-muted)]"
          />
          <button
            type="submit"
            class="px-4 py-2 rounded text-sm font-semibold bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors whitespace-nowrap"
          >
            Continue →
          </button>
        </div>
      </.form>
    </div>

    <div class="mt-6 text-xs text-[var(--text-tertiary)] space-y-1.5 text-center">
      <p :if={@params["as"] != "client"}>
        Organization need a new account?
        <a href={~p"/sign_up"} class={[link_style()]}>Sign up here.</a>
      </p>
      <p :if={@params["as"] != "client"}>
        Not sure where to start?
        <a href={~p"/?get_started=true&#{@params}"} class={[link_style()]}>Let's get started.</a>
      </p>
    </div>
    """
  end

  defp account_button(assigns) do
    ~H"""
    <a
      href={~p"/#{@account}?#{@params}"}
      class="w-full flex items-center gap-3 px-4 py-3 rounded border-2 border-[var(--border)] bg-[var(--surface)] hover:border-[var(--brand)] hover:shadow-sm transition-all duration-150 group"
    >
      <div class="w-9 h-9 rounded bg-[var(--brand)]/10 flex items-center justify-center shrink-0 group-hover:bg-[var(--brand)]/20 transition-colors">
        <span class="text-sm font-bold text-[var(--brand)]">
          {String.upcase(String.first(@account.name))}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors truncate">
          {@account.name}
        </p>
        <p class="text-xs text-[var(--text-tertiary)] truncate">{@account.slug}</p>
      </div>
      <svg
        class="w-4 h-4 text-[var(--text-muted)] group-hover:text-[var(--brand)] group-hover:translate-x-0.5 transition-all shrink-0"
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M6 3l5 5-5 5" />
      </svg>
    </a>
    """
  end
end
