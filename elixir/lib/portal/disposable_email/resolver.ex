defmodule Portal.DisposableEmail.Resolver do
  @moduledoc """
  Looks up MX records with the system's configured DNS servers.
  """

  @timeout :timer.seconds(2)

  @doc """
  Returns the lowercased mail hosts of the domain's MX records.

  The lookup gives up after #{@timeout} milliseconds in total, including retries.
  """
  @spec lookup_mx(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def lookup_mx(domain) do
    # The trailing dot makes the name absolute, so the resolver's search domains are not tried.
    case :inet_res.resolve(~c"#{domain}.", :in, :mx, [], @timeout) do
      {:ok, message} ->
        hosts =
          for record <- :inet_dns.msg(message, :anlist),
              :inet_dns.rr(record, :type) == :mx,
              {_preference, host} <- [:inet_dns.rr(record, :data)],
              do: host |> to_string() |> String.downcase()

        {:ok, hosts}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
