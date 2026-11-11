defmodule Portal.DisposableEmail do
  @moduledoc """
  Screens sign-up emails against the disposable email domain lists, see
  `Portal.DisposableEmail.Lists`.

  A listed domain matches itself and its subdomains. When `SIGN_UP_DISPOSABLE_MX_CHECK_ENABLED`
  is set, it also matches email domains whose mail servers are under it, which catches the new
  domains a disposable provider keeps adding. A match on the confirmed list blocks the sign-up, a
  match on the suspected list only flags it.

  The MX check is a network call, so it only runs on submit, and it allows the email when the
  lookup fails.
  """
  require Logger
  alias Portal.DisposableEmail.Lists

  @type source :: :domain | :mx
  @type verdict :: :ok | {:block, source()} | {:warn, source()}

  @doc """
  Returns the lowercased domain of an email address, without a trailing dot.
  """
  @spec email_domain(String.t() | nil) :: String.t() | nil
  def email_domain(email) when is_binary(email) do
    with [_local | _] = parts when length(parts) > 1 <- String.split(email, "@"),
         domain when domain != "" <- parts |> List.last() |> normalize_domain() do
      domain
    else
      _other -> nil
    end
  end

  def email_domain(nil), do: nil

  @doc """
  Screens an email domain. The confirmed list takes precedence, and the MX records are only looked
  up when the domain itself is not on the confirmed list.
  """
  @spec screen(String.t()) :: verdict()
  def screen(domain) when is_binary(domain) do
    domain = normalize_domain(domain)
    confirmed = Lists.domains(:confirmed, lists())
    suspected = Lists.domains(:suspected, lists())

    cond do
      listed?(domain, confirmed) ->
        {:block, :domain}

      MapSet.size(confirmed) == 0 and MapSet.size(suspected) == 0 ->
        :ok

      true ->
        mx_hosts = mx_hosts(domain)

        cond do
          Enum.any?(mx_hosts, &listed?(&1, confirmed)) -> {:block, :mx}
          listed?(domain, suspected) -> {:warn, :domain}
          Enum.any?(mx_hosts, &listed?(&1, suspected)) -> {:warn, :mx}
          true -> :ok
        end
    end
  end

  # "a.b.example.com" matches "a.b.example.com", "b.example.com" and "example.com", but never
  # the top-level domain alone.
  defp listed?(domain, list) do
    labels = domain |> normalize_domain() |> String.split(".")

    Enum.any?(0..max(length(labels) - 2, 0), fn i ->
      MapSet.member?(list, labels |> Enum.drop(i) |> Enum.join("."))
    end)
  end

  defp mx_hosts(domain) do
    if mx_check_enabled?() and valid_hostname?(domain) do
      case lookup_mx(domain) do
        {:ok, hosts} ->
          hosts

        {:error, reason} ->
          Logger.info("Disposable email MX lookup failed, allowing sign-up",
            email_domain: domain,
            reason: inspect(reason)
          )

          []
      end
    else
      []
    end
  end

  defp lookup_mx(domain) do
    lookup = Portal.Config.get_env(:portal, __MODULE__) |> Keyword.fetch!(:mx_lookup)
    lookup.(domain)
  end

  defp lists do
    Portal.Config.get_env(:portal, __MODULE__) |> Keyword.get(:lists, Lists)
  end

  defp normalize_domain(domain) do
    domain |> String.trim() |> String.downcase() |> String.trim_trailing(".")
  end

  defp valid_hostname?(domain) do
    byte_size(domain) <= 253 and Regex.match?(~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/, domain)
  end

  defp mx_check_enabled?,
    do: Portal.Config.get_env(:portal, :sign_up_disposable_mx_check_enabled, false)
end
