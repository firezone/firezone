defmodule Portal.Dashboard do
  @moduledoc """
  Context module for admin dashboard queries.
  """

  alias __MODULE__.Database

  @doc """
  Returns aggregate stat counts for the dashboard.
  """
  @spec stats(Portal.Authentication.Subject.t()) :: %{
          users: non_neg_integer(),
          service_accounts: non_neg_integer(),
          sites: non_neg_integer(),
          resources: non_neg_integer(),
          policies: non_neg_integer(),
          groups: non_neg_integer()
        }
  def stats(subject), do: Database.stats(subject)

  @doc """
  Returns health-related data for the dashboard: all sites and disabled auth providers.

  Sites without online gateways are computed in the LiveView by combining
  the returned sites list with real-time presence data.
  """
  @spec health_data(Portal.Authentication.Subject.t()) :: %{
          sites: [Portal.Site.t()],
          disabled_providers: list(),
          site_gateway_totals: %{String.t() => non_neg_integer()},
          site_resource_counts: %{String.t() => non_neg_integer()}
        }
  def health_data(subject), do: Database.health_data(subject)

  @doc """
  Returns the most recent client sessions, preloading the client and its actor.
  """
  @spec recent_sessions(Portal.Authentication.Subject.t(), non_neg_integer()) :: [
          Portal.ClientSession.t()
        ]
  def recent_sessions(subject, limit \\ 10), do: Database.recent_sessions(subject, limit)

  @doc """
  Returns the most recent policy authorizations, preloading the client, actor, and resource.
  """
  @spec recent_policy_authorizations(Portal.Authentication.Subject.t(), non_neg_integer()) :: [
          Portal.PolicyAuthorization.t()
        ]
  def recent_policy_authorizations(subject, limit \\ 10),
    do: Database.recent_policy_authorizations(subject, limit)

  @doc """
  Returns a map of gateway_id => name for the given list of gateway IDs.
  """
  @spec gateway_names(Portal.Authentication.Subject.t(), [String.t()]) :: %{
          String.t() => String.t()
        }
  def gateway_names(subject, gateway_ids), do: Database.gateway_names(subject, gateway_ids)

  defmodule Database do
    @moduledoc false
    import Ecto.Query

    alias Portal.Actor
    alias Portal.ClientSession
    alias Portal.EmailOTP
    alias Portal.Gateway
    alias Portal.PolicyAuthorization
    alias Portal.Entra
    alias Portal.Google
    alias Portal.Group
    alias Portal.OIDC
    alias Portal.Okta
    alias Portal.Policy
    alias Portal.Resource
    alias Portal.Safe
    alias Portal.Site
    alias Portal.Userpass

    def stats(subject) do
      users =
        from(a in Actor,
          where: a.type == :account_user,
          where: is_nil(a.disabled_at),
          select: count(a.id)
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      service_accounts =
        from(a in Actor, where: a.type == :service_account, select: count(a.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      sites =
        from(s in Site, where: s.managed_by == :account, select: count(s.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      resources =
        from(r in Resource, select: count(r.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      policies =
        from(p in Policy, where: is_nil(p.disabled_at), select: count(p.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      groups =
        from(g in Group, select: count(g.id))
        |> Safe.scoped(subject, :replica)
        |> Safe.one()
        |> then(&(&1 || 0))

      %{
        users: users,
        service_accounts: service_accounts,
        sites: sites,
        resources: resources,
        policies: policies,
        groups: groups
      }
    end

    def health_data(subject) do
      sites =
        from(s in Site, where: s.managed_by == :account, order_by: [asc: s.name])
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      disabled_providers = list_disabled_providers(subject)

      site_gateway_totals =
        from(g in Gateway, group_by: g.site_id, select: {g.site_id, count(g.id)})
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new()

      site_resource_counts =
        from(r in Resource,
          where: not is_nil(r.site_id),
          group_by: r.site_id,
          select: {r.site_id, count(r.id)}
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new()

      %{
        sites: sites,
        disabled_providers: disabled_providers,
        site_gateway_totals: site_gateway_totals,
        site_resource_counts: site_resource_counts
      }
    end

    def recent_sessions(subject, limit) do
      from(cs in ClientSession,
        order_by: [desc: cs.inserted_at],
        limit: ^limit,
        preload: [client: :actor]
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def recent_policy_authorizations(subject, limit) do
      from(pa in PolicyAuthorization,
        order_by: [desc: pa.inserted_at],
        limit: ^limit,
        preload: [client: :actor, resource: []]
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def gateway_names(subject, gateway_ids) do
      from(g in Gateway, where: g.id in ^gateway_ids, select: {g.id, g.name})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Map.new()
    end

    defp list_disabled_providers(subject) do
      [
        from(p in EmailOTP.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all(),
        from(p in Userpass.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all(),
        from(p in Google.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all(),
        from(p in Entra.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all(),
        from(p in Okta.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all(),
        from(p in OIDC.AuthProvider, where: p.is_disabled == true)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
      ]
      |> List.flatten()
    end
  end
end
