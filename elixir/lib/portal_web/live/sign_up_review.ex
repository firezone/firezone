defmodule PortalWeb.SignUpReview do
  @moduledoc """
  Holds back email sign-ups from unknown mail servers until an approver approves them.

  After the email is verified, `check/3` looks up the MX hosts of the email domain.
  When every host is a `Portal.KnownMxDomain` or a subdomain of one, the account is
  created as usual. Otherwise each `SIGN_UP_REVIEW_APPROVERS` address gets a personal
  link to this page, see `Portal.Workers.SignUpReviewRequest`. Approving trusts the
  selected mail server domains, creates the account and tells all approvers. Google and
  GitHub sign-ups skip this.

  The links are encrypted and expire 72 hours after the sign-up. A link only works
  while its approver is still listed. Opening the page changes nothing, so mail
  scanners that open links cannot approve. Only domains derived from the sign-up's own
  MX hosts can be trusted.
  """
  use PortalWeb, {:live_view, layout: {PortalWeb.Layouts, :auth}}
  alias __MODULE__.Database
  alias Portal.Workers.SignUpReviewRequest
  require Logger

  @review_salt "sign_up_review_v1"
  @approver_salt "sign_up_review_approver_v1"
  @max_age 3 * 86_400

  # Second-level labels under which a "parent" domain would be a public suffix.
  @public_second_levels ~w[ac co com edu go gov ne net or org]

  @doc """
  Returns `:ok` when the verified email sign-up can create its account now: review is
  off, the email already owns an account, or all its MX hosts are known. Otherwise asks
  the approvers to review it and returns `:pending_review`.
  """
  @spec check(map(), String.t() | nil, :inet.ip_address()) :: :ok | :pending_review | {:error, String.t()}
  def check(%{email: email} = registration_claims, user_agent, real_ip) do
    with true <- SignUpReviewRequest.enabled?(),
         false <- PortalWeb.SignUp.owner_email_registered?(email),
         {:review, mx_hosts} <- classify(email) do
      request_review(registration_claims, mx_hosts, user_agent, real_ip)
    else
      # Review is off, or the email already owns an account.
      boolean when is_boolean(boolean) -> :ok
      :known -> :ok
    end
  end

  @doc "Decrypts a sign-up held for review, unless it is older than 72 hours."
  @spec decrypt_review(String.t()) :: {:ok, map()} | :error
  def decrypt_review(encrypted_review) do
    case Phoenix.Token.decrypt(PortalWeb.Endpoint, @review_salt, encrypted_review, max_age: @max_age) do
      {:ok, review} -> {:ok, review}
      {:error, _reason} -> :error
    end
  end

  @doc "The approval link for one approver."
  @spec approval_url(String.t(), String.t()) :: String.t()
  def approval_url(encrypted_review, approver) do
    token =
      Phoenix.Token.encrypt(PortalWeb.Endpoint, @approver_salt, %{
        review: encrypted_review,
        approver: approver
      })

    url(~p"/sign_up/review?token=#{token}")
  end

  def mount(params, _session, socket) do
    socket = assign(socket, page_title: "Review Sign Up", step: :invalid, error: nil)

    with %{"token" => token} <- params,
         {:ok, %{review: encrypted_review, approver: approver}} <-
           Phoenix.Token.decrypt(PortalWeb.Endpoint, @approver_salt, token, max_age: @max_age),
         true <- approver in SignUpReviewRequest.approvers(),
         {:ok, review} <- decrypt_review(encrypted_review) do
      {:ok,
       assign(socket,
         step: :review,
         review: review,
         approver: approver,
         suggested_domains: suggested_domains(review.mx_hosts)
       )}
    else
      _ -> {:ok, socket}
    end
  end

  def handle_event("approve", params, %{assigns: %{step: :review}} = socket) do
    %{review: review, approver: approver, suggested_domains: suggested} = socket.assigns
    domains = params |> Map.get("domains", []) |> List.wrap() |> Enum.filter(&(&1 in suggested))

    with true <- approver in SignUpReviewRequest.approvers(),
         :ok <- Database.insert_domains(domains),
         {:ok, result} <-
           PortalWeb.SignUp.complete_email_sign_up(review.registration, review.user_agent, review.real_ip) do
      Logger.info("Sign-up approved",
        account_id: result.account.id,
        approved_by: approver,
        trusted_domains: Enum.join(domains, ",")
      )

      send_approved_email(review, approver, result.account, domains)
      {:noreply, assign(socket, step: :approved, account: result.account)}
    else
      false ->
        {:noreply, assign(socket, step: :invalid)}

      {:error, {:account_exists, _accounts}} ->
        {:noreply, assign(socket, step: :exists)}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "Could not approve the sign-up. Please try again.")}
    end
  end

  def handle_event("approve", _params, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div :if={@step == :invalid}>
      <h1 class="text-xl font-bold text-heading tracking-tight mb-2">Link not valid</h1>
      <p class="text-sm text-body">This review link is invalid or has expired.</p>
    </div>

    <div :if={@step == :review}>
      <h1 class="text-xl font-bold text-heading tracking-tight mb-6">Review sign-up</h1>

      <dl class="rounded border border-border bg-raised p-4 mb-6 space-y-2 text-sm">
        <div>
          <dt class="text-xs text-subtle">Name</dt>
          <dd class="text-heading">{@review.registration.actor_name}</dd>
        </div>
        <div>
          <dt class="text-xs text-subtle">Email</dt>
          <dd class="text-heading">{@review.registration.email}</dd>
        </div>
        <div>
          <dt class="text-xs text-subtle">Company</dt>
          <dd class="text-heading">{@review.registration.company_name}</dd>
        </div>
        <div>
          <dt class="text-xs text-subtle">Mail servers</dt>
          <dd :for={host <- @review.mx_hosts} class="text-heading font-mono">{host}</dd>
          <dd :if={@review.mx_hosts == []} class="text-heading">None found</dd>
        </div>
      </dl>

      <.form for={%{}} id="sign-up-review-form" phx-submit="approve" class="flex flex-col gap-3">
        <fieldset :if={@suggested_domains != []} class="flex flex-col gap-2">
          <legend class="text-sm font-medium text-heading mb-2">
            Trust these mail server domains for future sign-ups
          </legend>
          <label :for={domain <- @suggested_domains} class="flex items-center gap-2 text-sm text-body">
            <input type="checkbox" name="domains[]" value={domain} checked />
            <span class="font-mono">{domain}</span>
          </label>
        </fieldset>
        <p :if={@error} class="text-sm text-danger">{@error}</p>
        <button
          type="submit"
          phx-disable-with="Approving..."
          class="w-full py-2.5 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors"
        >
          Approve and create account
        </button>
      </.form>
    </div>

    <div :if={@step == :approved}>
      <h1 class="text-xl font-bold text-heading tracking-tight mb-2">Sign-up approved</h1>
      <p class="text-sm text-body">
        Account {@account.name} is created and the welcome email is sent to {@review.registration.email}.
      </p>
    </div>

    <div :if={@step == :exists}>
      <h1 class="text-xl font-bold text-heading tracking-tight mb-2">Already approved</h1>
      <p class="text-sm text-body">{@review.registration.email} already has an account.</p>
    </div>
    """
  end

  defp classify(email) do
    hosts =
      case email_domain(email) do
        {:ok, domain} -> lookup_mx(domain)
        :error -> []
      end

    if all_known?(hosts), do: :known, else: {:review, hosts}
  end

  defp request_review(registration_claims, mx_hosts, user_agent, real_ip) do
    encrypted_review =
      Phoenix.Token.encrypt(PortalWeb.Endpoint, @review_salt, %{
        registration: Map.delete(registration_claims, :browser),
        user_agent: user_agent,
        real_ip: real_ip,
        mx_hosts: mx_hosts
      })

    case SignUpReviewRequest.enqueue(registration_claims.email, encrypted_review) do
      :ok ->
        :pending_review

      {:error, reason} ->
        Logger.error("Failed to request sign-up review", reason: inspect(reason))
        {:error, "We encountered a temporary error. Please try again."}
    end
  end

  defp send_approved_email(review, approver, account, domains) do
    review
    |> Portal.Mailer.InternalEmail.sign_up_approved_email(
      SignUpReviewRequest.approvers(),
      approver,
      account,
      domains
    )
    |> Portal.Mailer.enqueue()
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue sign-up approved email",
          account_id: account.id,
          reason: inspect(reason)
        )
    end
  end

  defp email_domain(email) do
    domain =
      email
      |> String.split("@")
      |> List.last()
      |> String.trim()
      |> String.trim_trailing(".")

    case domain != "" and Portal.Changeset.try_encode_domain(domain) do
      {:ok, ascii} -> {:ok, String.downcase(ascii)}
      _ -> :error
    end
  end

  defp lookup_mx(domain) do
    resolve =
      Portal.Config.get_env(:portal, __MODULE__, [])[:resolve_mx] ||
        (&:inet_res.resolve(&1, :in, :mx, timeout: 3_000))

    case resolve.(String.to_charlist(domain)) do
      {:ok, message} ->
        for record <- :inet_dns.msg(message, :anlist),
            :inet_dns.rr(record, :type) == :mx,
            {_preference, host} <- [:inet_dns.rr(record, :data)],
            do: normalize_host(host)

      {:error, reason} ->
        Logger.info("MX lookup failed during sign-up", domain: domain, reason: inspect(reason))
        []
    end
  end

  # A null MX (RFC 7505) is "." and becomes "", which never matches.
  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp all_known?([]), do: false

  defp all_known?(hosts) do
    known = known_domains(hosts)
    Enum.all?(hosts, &known_host?(&1, known))
  end

  defp known_domains(hosts) do
    hosts |> Enum.flat_map(&label_suffixes/1) |> Enum.uniq() |> Database.known_domains()
  end

  defp known_host?(host, known) do
    Regex.match?(Portal.KnownMxDomain.format(), host) and
      Enum.any?(label_suffixes(host), &MapSet.member?(known, &1))
  end

  # "mx1.mail.example.com" -> ["mx1.mail.example.com", "mail.example.com", "example.com", "com"]
  defp label_suffixes(host) do
    labels = String.split(host, ".")
    for index <- 0..(length(labels) - 1)//1, do: labels |> Enum.drop(index) |> Enum.join(".")
  end

  # Unknown hosts minus their first label, so "mx1.example.com" suggests "example.com".
  # The host itself is suggested when its parent would be a public suffix like "co.uk".
  defp suggested_domains(hosts) do
    known = known_domains(hosts)

    hosts
    |> Enum.filter(&Regex.match?(Portal.KnownMxDomain.format(), &1))
    |> Enum.reject(&known_host?(&1, known))
    |> Enum.map(&parent_domain/1)
    |> Enum.uniq()
  end

  defp parent_domain(host) do
    case String.split(host, ".") do
      [_first | [second_level, _tld] = parent] when second_level not in @public_second_levels ->
        Enum.join(parent, ".")

      [_first, _second, _third, _fourth | _rest] = labels ->
        labels |> tl() |> Enum.join(".")

      _labels ->
        host
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def known_domains(domains) do
      from(d in Portal.KnownMxDomain, where: d.domain in ^domains, select: d.domain)
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end

    def insert_domains(domains) do
      Enum.reduce_while(domains, :ok, fn domain, :ok ->
        %Portal.KnownMxDomain{}
        |> Ecto.Changeset.cast(%{domain: domain}, [:domain])
        |> Portal.KnownMxDomain.changeset()
        |> Safe.unscoped()
        |> Safe.insert(on_conflict: :nothing)
        |> case do
          {:ok, _known_mx_domain} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end
end
