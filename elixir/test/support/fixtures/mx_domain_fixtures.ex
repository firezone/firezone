defmodule Portal.MXDomainFixtures do
  @moduledoc """
  Test helpers for rating mail server domains and answering MX lookups.
  """

  def mx_domain_fixture(domain, rating \\ :bad, note \\ "Disposable email service") do
    %Portal.MXDomain{}
    |> Ecto.Changeset.cast(%{domain: domain, rating: rating, note: note}, [:domain, :rating, :note])
    |> Portal.MXDomain.changeset()
    |> Portal.Repo.insert!()
  end

  @doc """
  Answers MX lookups made by this process and the processes it starts with `fun.(domain)`.
  """
  def stub_mx(fun) when is_function(fun, 1) do
    Portal.Config.put_env_override(:portal, Portal.MXDomains, mx_lookup: fun)
  end

  @doc """
  The default MX lookup in tests, so they never query DNS: no domain has mail servers.
  """
  def no_mx(_domain), do: {:ok, []}
end
