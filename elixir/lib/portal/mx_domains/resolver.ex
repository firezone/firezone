defmodule Portal.MXDomains.Resolver do
  @moduledoc """
  Looks up MX records with the system's configured DNS servers.
  """

  # Sign-up waits for the lookup, so keep it short.
  @timeout :timer.seconds(2)

  @doc """
  Returns the lowercased mail hosts of the domain's MX records, without a null
  MX (`0 .`), which says the domain accepts no mail.

  The lookup gives up after #{@timeout} milliseconds in total, including retries.
  """
  @spec lookup_mx(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def lookup_mx(domain) do
    # The trailing dot makes the name absolute, so the resolver's search domains are not tried.
    case :inet_res.resolve(~c"#{domain}.", :in, :mx, [], @timeout) do
      {:ok, message} -> {:ok, mx_hosts(message)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Public so the parsing can be tested without DNS.
  @spec mx_hosts(term()) :: [String.t()]
  def mx_hosts(message) do
    for record <- :inet_dns.msg(message, :anlist),
        :inet_dns.rr(record, :type) == :mx,
        {_preference, host} <- [:inet_dns.rr(record, :data)],
        host = host |> to_string() |> String.downcase(),
        host not in [".", ""],
        do: host
  end
end
