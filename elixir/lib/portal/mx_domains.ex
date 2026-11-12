defmodule Portal.MXDomains do
  @moduledoc """
  Checks an email address's mail servers against the bad `Portal.MXDomain` entries.
  """

  alias __MODULE__.Database
  alias Portal.MXDomain
  require Logger

  @type check_rating :: MXDomain.rating() | :unknown
  @type match :: %{email_domain: String.t(), mx_host: String.t() | nil, mx_domain: String.t() | nil}

  @doc """
  Rates an email address by its domain's mail servers, or by the domain itself when
  it has no MX records.

  One bad mail server makes the address bad, otherwise one unrated mail server makes
  it unknown, and it is good only when every mail server falls under a good domain.
  The match names the mail server that decided the rating and the domain it falls
  under, or the first mail server when all are good.

  Returns `:unchecked` when the email has no domain or the lookup fails, so DNS
  problems never block a sign-up.
  """
  @spec check_email(String.t()) :: {check_rating(), match()} | :unchecked
  def check_email(email) when is_binary(email) do
    with domain when is_binary(domain) <- email_domain(email),
         {:ok, hosts} <- lookup_mx(domain) do
      check_hosts(domain, hosts)
    else
      _ -> :unchecked
    end
  end

  @doc """
  Returns the lowercased domain of an email address, or `nil` if it has none.
  """
  @spec email_domain(String.t()) :: String.t() | nil
  def email_domain(email) when is_binary(email) do
    case email |> String.trim() |> String.split("@") do
      [_local | [_ | _] = rest] ->
        case rest |> List.last() |> MXDomain.normalize_domain() do
          "" -> nil
          domain -> domain
        end

      _ ->
        nil
    end
  end

  # Mail is delivered to the domain itself when it has no MX records (RFC 5321).
  defp check_hosts(domain, []) do
    candidates = MXDomain.candidates(domain)
    {rating, mx_domain} = rate(candidates, Database.ratings(candidates))
    {rating, %{email_domain: domain, mx_host: nil, mx_domain: mx_domain}}
  end

  defp check_hosts(domain, hosts) do
    candidates_by_host = Map.new(hosts, &{&1, MXDomain.candidates(&1)})
    ratings = candidates_by_host |> Map.values() |> List.flatten() |> Database.ratings()

    rated_hosts =
      Enum.map(hosts, fn host ->
        {rating, mx_domain} = rate(candidates_by_host[host], ratings)
        {rating, %{email_domain: domain, mx_host: host, mx_domain: mx_domain}}
      end)

    Enum.find(rated_hosts, &match?({:bad, _match}, &1)) ||
      Enum.find(rated_hosts, &match?({:unknown, _match}, &1)) ||
      hd(rated_hosts)
  end

  # Candidates run from most to least specific, so the most specific domain of the
  # winning rating is returned, e.g. `in.mail.tm` over `mail.tm`.
  defp rate(candidates, ratings) do
    rated = for candidate <- candidates, rating = ratings[candidate], do: {rating, candidate}

    List.keyfind(rated, :bad, 0) || List.keyfind(rated, :good, 0) || {:unknown, nil}
  end

  defp lookup_mx(domain) do
    mx_lookup = Portal.Config.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(:mx_lookup)

    case mx_lookup.(domain) do
      {:ok, hosts} ->
        {:ok, hosts}

      {:error, reason} ->
        Logger.info("MX lookup failed, allowing sign-up", email_domain: domain, reason: inspect(reason))
        :error
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.MXDomain
    alias Portal.Safe

    def ratings(candidates) do
      from(d in MXDomain, where: d.domain in ^candidates, select: {d.domain, d.rating})
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end
  end
end
