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
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
        <span class="text-sm font-semibold text-heading">Firezone</span>
      </div>
      <h1 class="text-2xl font-bold text-heading tracking-tight">Let's get started!</h1>
      <p class="text-sm text-body mt-2">Which best describes why you're here?</p>
    </div>

    <div class="space-y-2.5">
      <a
        href={~p"/sign_up"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-border bg-surface hover:border-brand transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-brand/10">
          <.icon name="ri-building-line" class="w-6 h-6 text-brand" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-heading group-hover:text-brand transition-colors">
            Set up a new organization
          </p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">
            Create an admin account for your team.
          </p>
        </div>
        <.icon
          name="ri-arrow-right-s-line"
          class="w-5.5 h-5.5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
        />
      </a>

      <a
        href={~p"/find_account?#{@params}"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-border bg-surface hover:border-brand transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-violet-500/10 dark:bg-violet-400/10">
          <.icon name="ri-team-line" class="w-5 h-5 text-violet-500 dark:text-violet-400" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-heading group-hover:text-brand transition-colors">
            My company uses Firezone
          </p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">
            Find your organization's sign-in page.
          </p>
        </div>
        <.icon
          name="ri-arrow-right-s-line"
          class="w-5.5 h-5.5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
        />
      </a>

      <a
        href={~p"/sign_in?#{@params}"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-border bg-surface hover:border-brand transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-slate-100 dark:bg-slate-800">
          <.icon name="ri-terminal-line" class="w-5 h-5 text-slate-500 dark:text-slate-400" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-heading group-hover:text-brand transition-colors">
            I know what I'm doing
          </p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">
            Go straight to account sign-in.
          </p>
        </div>
        <.icon
          name="ri-arrow-right-s-line"
          class="w-5.5 h-5.5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
        />
      </a>
    </div>
    """
  end

  defp account_chooser(assigns) do
    ~H"""
    <%!-- Branded header --%>
    <div class="flex items-center gap-3 mb-8">
      <div class="w-10 h-10 rounded bg-brand/10 border border-brand/20 flex items-center justify-center shrink-0 lg:hidden">
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
      </div>
      <div>
        <h1 class="text-xl font-bold text-heading tracking-tight">
          Sign in to Firezone
        </h1>
        <p class="text-xs text-subtle mt-0.5">
          Choose your organization to continue.
        </p>
      </div>
    </div>

    <%!-- Recently signed in --%>
    <div :if={@accounts != []}>
      <div class="flex items-center gap-3 mb-3">
        <div class="flex-1 h-px bg-border"></div>
        <span class="text-xs font-medium text-muted uppercase tracking-widest">
          Recently signed in
        </span>
        <div class="flex-1 h-px bg-border"></div>
      </div>
      <div class="flex flex-col gap-2 mb-6">
        <.account_button :for={account <- @accounts} account={account} params={@params} />
      </div>
    </div>

    <%!-- Slug entry card --%>
    <div class="rounded border border-border bg-raised p-4">
      <p class="text-xs font-semibold text-body mb-3">
        Enter your organization's account slug
      </p>
      <.form :let={f} for={%{}} action={~p"/sign_in?#{@params}"}>
        <div class="flex gap-2">
          <input
            type="text"
            name={f[:account_id_or_slug].name}
            placeholder="e.g. acme-corp"
            autofocus={@accounts == []}
            required
            class="flex-1 px-3 py-2 text-sm rounded border bg-input border-input-border text-heading outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors placeholder:text-muted"
          />
          <button
            type="submit"
            class="px-4 py-2 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors whitespace-nowrap"
          >
            Continue →
          </button>
        </div>
      </.form>
    </div>

    <div class="mt-6 text-xs text-subtle space-y-1.5 text-center">
      <p :if={!PortalWeb.Authentication.client_sign_in?(@params)}>
        Want to set up a new Organization?
        <a href={~p"/sign_up"} class={[link_style()]}>Sign up here.</a>
      </p>
      <p :if={!PortalWeb.Authentication.client_sign_in?(@params)}>
        Not sure where to start?
        <a href={~p"/getting_started?#{@params}"} class={[link_style()]}>Let's get started.</a>
      </p>
    </div>
    """
  end

  defp account_button(assigns) do
    ~H"""
    <a
      href={~p"/#{@account}/sign_in?#{@params}"}
      class="w-full flex items-center gap-3 px-4 py-3 rounded border-2 border-border bg-surface hover:border-brand hover:shadow-sm transition-all duration-150 group"
    >
      <div class="w-9 h-9 rounded bg-brand/10 flex items-center justify-center shrink-0 group-hover:bg-brand/20 transition-colors">
        <span class="text-sm font-bold text-brand">
          {String.upcase(String.first(@account.name))}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold text-heading group-hover:text-brand transition-colors truncate">
          {@account.name}
        </p>
        <p class="text-xs text-subtle truncate">{@account.slug}</p>
      </div>
      <.icon
        name="ri-arrow-right-s-line"
        class="w-5.5 h-5.5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
      />
    </a>
    """
  end
end
