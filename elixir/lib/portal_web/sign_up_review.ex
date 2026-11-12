defmodule PortalWeb.SignUpReview do
  @moduledoc """
  Checks the mail servers of email sign-ups against `Portal.KnownMxDomain`.

  After the email is verified, `check/3` looks up the MX hosts of the email domain:

    * any host matches a `:deny` domain: the sign-up is blocked
    * every host matches an `:allow` domain: the account is created as usual
    * otherwise each `SIGN_UP_REVIEW_APPROVERS` address gets a personal link to the
      review page on the ops endpoint, see `Portal.Workers.SignUpReviewRequest` and
      `PortalOps.SignUpReviewController`

  Google and GitHub sign-ups skip this. The links are encrypted, expire 72 hours after
  the sign-up and only work while their approver is still listed.
  """
  alias __MODULE__.Database
  alias Portal.Workers.SignUpReviewRequest
  require Logger

  @review_salt "sign_up_review_v1"
  @approver_salt "sign_up_review_approver_v1"
  @max_age 3 * 86_400

  # Sign-up waits for the lookup. This is the total time, including retries.
  @lookup_timeout :timer.seconds(3)

  @blocked_message "Sign-ups from this email domain are not allowed. Please use a different email address."

  @doc """
  Returns `:ok` when the verified email sign-up can create its account now: review is
  off, the email already owns an account, or all its MX hosts are allowed. Returns an
  error when any MX host is denied. Otherwise asks the approvers to review it and
  returns `:pending_review`.
  """
  @spec check(map(), String.t() | nil, :inet.ip_address()) :: :ok | :pending_review | {:error, String.t()}
  def check(%{email: email} = registration_claims, user_agent, real_ip) do
    with true <- SignUpReviewRequest.enabled?(),
         false <- PortalWeb.SignUp.owner_email_registered?(email),
         {:review, mail_servers} <- classify(email) do
      request_review(registration_claims, mail_servers, user_agent, real_ip)
    else
      # Review is off, or the email already owns an account.
      boolean when is_boolean(boolean) -> :ok
      :allowed -> :ok
      :denied -> {:error, @blocked_message}
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

  @doc "The token of one approver's review link."
  @spec approval_token(String.t(), String.t()) :: String.t()
  def approval_token(encrypted_review, approver) do
    Phoenix.Token.encrypt(PortalWeb.Endpoint, @approver_salt, %{
      review: encrypted_review,
      approver: approver
    })
  end

  @doc "Returns the review and approver of a review link while the approver is still listed."
  @spec verify_approval(term()) :: {:ok, map(), String.t()} | :error
  def verify_approval(token) when is_binary(token) do
    with {:ok, %{review: encrypted_review, approver: approver}} <-
           Phoenix.Token.decrypt(PortalWeb.Endpoint, @approver_salt, token, max_age: @max_age),
         true <- approver in SignUpReviewRequest.approvers(),
         {:ok, review} <- decrypt_review(encrypted_review) do
      {:ok, review, approver}
    else
      _ -> :error
    end
  end

  def verify_approval(_token), do: :error

  @doc """
  The domains an MX host matches on, from the host itself down to two labels.

      iex> PortalWeb.SignUpReview.label_suffixes("mx1.mail.example.com")
      ["mx1.mail.example.com", "mail.example.com", "example.com"]
  """
  @spec label_suffixes(String.t()) :: [String.t()]
  def label_suffixes(host) do
    labels = String.split(host, ".", trim: true)
    for count <- length(labels)..2//-1, do: labels |> Enum.take(-count) |> Enum.join(".")
  end

  defp classify(email) do
    {domain, hosts} =
      case email_domain(email) do
        {:ok, domain} -> {domain, mail_hosts(domain)}
        :error -> {nil, []}
      end

    mail_servers = with_verdicts(hosts)
    verdicts = Enum.map(mail_servers, fn {_host, verdict} -> verdict end)

    cond do
      :deny in verdicts ->
        Logger.info("Sign-up blocked", email_domain: domain, mx_hosts: Enum.join(hosts, ","))
        :denied

      verdicts != [] and Enum.all?(verdicts, &(&1 == :allow)) ->
        :allowed

      true ->
        Logger.info("Sign-up held for review", email_domain: domain, mx_hosts: Enum.join(hosts, ","))
        {:review, mail_servers}
    end
  end

  # A domain without MX records receives mail itself (RFC 5321). A null MX (RFC 7505)
  # says it receives none, so it stays "." and never matches.
  defp mail_hosts(domain) do
    case lookup_mx(domain) do
      {:ok, []} -> [domain]
      {:ok, hosts} -> hosts
      :error -> []
    end
  end

  defp request_review(registration_claims, mail_servers, user_agent, real_ip) do
    encrypted_review =
      Phoenix.Token.encrypt(PortalWeb.Endpoint, @review_salt, %{
        registration: Map.delete(registration_claims, :browser),
        user_agent: user_agent,
        real_ip: real_ip,
        mail_servers: mail_servers
      })

    case SignUpReviewRequest.enqueue(registration_claims.email, encrypted_review) do
      :ok ->
        :pending_review

      {:error, reason} ->
        Logger.error("Failed to request sign-up review", reason: inspect(reason))
        {:error, "We encountered a temporary error. Please try again."}
    end
  end

  defp email_domain(email) do
    with [_local | [_ | _] = rest] <- email |> String.trim() |> String.split("@"),
         domain = Portal.KnownMxDomain.normalize(List.last(rest)),
         true <- domain != "",
         {:ok, ascii} <- Portal.Changeset.try_encode_domain(domain) do
      {:ok, String.downcase(ascii)}
    else
      _ -> :error
    end
  end

  defp lookup_mx(domain) do
    resolve =
      Portal.Config.get_env(:portal, __MODULE__, [])[:resolve_mx] ||
        (&:inet_res.resolve(&1, :in, :mx, [], @lookup_timeout))

    # The trailing dot makes the name absolute, so the resolver's search domains are not tried.
    case resolve.(~c"#{domain}.") do
      {:ok, message} ->
        hosts =
          for record <- :inet_dns.msg(message, :anlist),
              :inet_dns.rr(record, :type) == :mx,
              {_preference, host} <- [:inet_dns.rr(record, :data)],
              do: normalize_host(host)

        {:ok, hosts}

      {:error, reason} ->
        Logger.info("MX lookup failed during sign-up", email_domain: domain, reason: inspect(reason))
        :error
    end
  end

  defp normalize_host(host) do
    case host |> to_string() |> Portal.KnownMxDomain.normalize() do
      "" -> "."
      host -> host
    end
  end

  # Each host with :deny when any of its domains is denied, else :allow when one is
  # allowed and the host is well formed, else :unknown.
  defp with_verdicts(hosts) do
    verdicts = hosts |> Enum.flat_map(&label_suffixes/1) |> Enum.uniq() |> Database.verdicts()

    Enum.map(hosts, fn host ->
      found = host |> label_suffixes() |> Enum.map(&Map.get(verdicts, &1))

      cond do
        :deny in found -> {host, :deny}
        :allow in found and Regex.match?(Portal.KnownMxDomain.format(), host) -> {host, :allow}
        true -> {host, :unknown}
      end
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def verdicts(domains) do
      from(d in Portal.KnownMxDomain, where: d.domain in ^domains, select: {d.domain, d.verdict})
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end
  end
end
