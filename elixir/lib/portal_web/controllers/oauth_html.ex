defmodule PortalWeb.OAuthHTML do
  use PortalWeb, :html

  def consent(assigns) do
    ~H"""
    <.flash kind={:error} flash={@flash} />

    <div class="mb-8 text-center">
      <div class="flex items-center justify-center gap-2 mb-8">
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
        <span class="text-sm font-semibold text-heading">Firezone</span>
      </div>

      <h1 class="text-2xl font-bold text-heading tracking-tight">
        Connect {@request.client.client_name}?
      </h1>
      <p class="text-sm text-body mt-2">
        It is asking to use <span class="font-semibold text-heading">{@account.name}</span>
        as {@subject.actor.name}.
      </p>
    </div>

    <div class="rounded border-2 border-border bg-surface divide-y divide-border mb-6">
      <div :for={scope <- @request.scopes} class="flex items-start gap-3 px-4 py-3.5">
        <div class={[
          "w-8 h-8 rounded shrink-0 flex items-center justify-center",
          scope_tone(scope)
        ]}>
          <.icon name={scope_icon(scope)} class="w-5 h-5" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-heading">{scope_title(scope)}</p>
          <p class="text-xs text-subtle mt-0.5 leading-relaxed">{scope_detail(scope)}</p>
        </div>
      </div>
    </div>

    <p class="text-xs text-subtle leading-relaxed mb-6">
      This app can only do what you can do. You can disconnect it at any time from your
      account settings, which immediately stops any access it still holds.
    </p>

    <.form for={%{}} action={~p"/#{@account}/oauth/authorize"} method="post">
      <input :for={{name, value} <- carried_params(@request)} type="hidden" name={name} value={value} />

      <div class="flex gap-2.5">
        <button
          type="submit"
          name="decision"
          value="deny"
          class="flex-1 px-4 py-2.5 rounded border-2 border-border bg-surface text-sm font-semibold text-heading hover:border-brand transition-all duration-150"
        >
          Cancel
        </button>
        <button
          type="submit"
          name="decision"
          value="allow"
          class="flex-1 px-4 py-2.5 rounded border-2 border-brand bg-brand text-sm font-semibold text-white hover:opacity-90 transition-all duration-150"
        >
          Connect
        </button>
      </div>
    </.form>

    <p class="text-xs text-subtle text-center mt-6 break-all">
      You will be returned to {redirect_host(@request.redirect_uri)}
    </p>
    """
  end

  def choose_account(assigns) do
    ~H"""
    <div class="mb-8 text-center">
      <div class="flex items-center justify-center gap-2 mb-8">
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
        <span class="text-sm font-semibold text-heading">Firezone</span>
      </div>

      <h1 class="text-2xl font-bold text-heading tracking-tight">Which account?</h1>
      <p class="text-sm text-body mt-2">
        Pick the Firezone account you want to connect the app to.
      </p>
    </div>

    <div :if={@accounts != []} class="space-y-2.5 mb-6">
      <a
        :for={account <- @accounts}
        href={~p"/#{account}/oauth/authorize?#{@query}"}
        class="w-full flex items-center gap-3 px-4 py-3.5 rounded border-2 border-border bg-surface hover:border-brand transition-all duration-150 group"
      >
        <div class="w-10 h-10 rounded shrink-0 flex items-center justify-center bg-brand/10">
          <.icon name="ri-building-line" class="w-6 h-6 text-brand" />
        </div>
        <p class="flex-1 min-w-0 text-sm font-semibold text-heading group-hover:text-brand transition-colors">
          {account.name}
        </p>
      </a>
    </div>

    <form action={~p"/sign_in"} method="get" class="space-y-2.5">
      <label for="account_id_or_slug" class="block text-sm font-semibold text-heading">
        Or enter your account ID
      </label>
      <input
        type="text"
        id="account_id_or_slug"
        name="account_id_or_slug"
        placeholder="your-account"
        class="w-full px-4 py-2.5 rounded border-2 border-border bg-surface text-sm text-heading"
      />
      <p class="text-xs text-subtle leading-relaxed">
        Sign in there first, then start the connection again from the app.
      </p>
    </form>
    """
  end

  def error(assigns) do
    ~H"""
    <div class="text-center">
      <div class="flex items-center justify-center gap-2 mb-8">
        <img src="/images/logo.svg" class="w-5 h-5" alt="Firezone Logo" />
        <span class="text-sm font-semibold text-heading">Firezone</span>
      </div>

      <div class="w-12 h-12 rounded mx-auto mb-4 flex items-center justify-center bg-danger/10">
        <.icon name="ri-error-warning-line" class="w-7 h-7 text-danger" />
      </div>

      <h1 class="text-2xl font-bold text-heading tracking-tight">This request is not valid</h1>
      <p class="text-sm text-body mt-2">{@description}</p>
      <p class="text-xs text-subtle mt-6">
        Nothing was shared. Close this window and try connecting again from the app.
      </p>
    </div>
    """
  end

  # Everything the POST needs to rebuild and re-check the request. Nothing here
  # is trusted on the way back in; it is re-validated from scratch.
  defp carried_params(request) do
    [
      {"client_id", request.client.client_id},
      {"redirect_uri", request.redirect_uri},
      {"response_type", "code"},
      {"scope", Portal.OAuth.Scope.encode(request.scopes)},
      {"resource", request.resource},
      {"code_challenge", request.code_challenge},
      {"code_challenge_method", "S256"},
      {"state", request.state}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp scope_title("mcp:read"), do: "See your configuration"
  defp scope_title("mcp:write"), do: "Change your configuration"
  defp scope_title(scope), do: scope

  defp scope_detail("mcp:read") do
    "Read your sites, resources, policies, groups, people, connected clients, and logs."
  end

  defp scope_detail("mcp:write") do
    "Create, edit, and delete those same things, including granting people access."
  end

  defp scope_detail(_scope), do: ""

  defp scope_icon("mcp:write"), do: "ri-edit-line"
  defp scope_icon(_scope), do: "ri-eye-line"

  defp scope_tone("mcp:write"), do: "bg-danger/10 text-danger"
  defp scope_tone(_scope), do: "bg-brand/10 text-brand"

  defp redirect_host(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{host: host, port: port} when is_binary(host) -> "#{host}:#{port}"
      _other -> redirect_uri
    end
  end
end
