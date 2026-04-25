# credo:disable-for-this-file
defmodule Portal.Dev.AccountPopulation do
  import Ecto.Changeset
  import Ecto.Query

  alias Portal.Account
  alias Portal.Actor
  alias Portal.AuthProvider
  alias Portal.Authentication
  alias Portal.ClientSession
  alias Portal.Crypto
  alias Portal.Device
  alias Portal.EmailOTP
  alias Portal.GatewaySession
  alias Portal.Group
  alias Portal.Membership
  alias Portal.Policy
  alias Portal.Repo
  alias Portal.Resource
  alias Portal.Site

  alias Portal.Authentication.{Context, Credential, Subject}

  @default_user_agent "account-population/1.0 connlib/1.4.0"
  @gateway_user_agent "Linux x86_64 connlib/1.4.0"
  @default_gateway_remote_ip {198, 51, 100, 10}
  @default_client_remote_ip {203, 0, 113, 10}
  @default_password "Firezone1234"
  @support_email_domain "example.test"

  @plan_specs %{
    starter: %{
      product_name: "Starter",
      support_type: "community",
      features: %{
        policy_conditions: false,
        traffic_filters: false,
        idp_sync: false,
        rest_api: false,
        internet_resource: false
      },
      limits: %{
        users_count: 6,
        monthly_active_users_count: nil,
        service_accounts_count: 10,
        sites_count: 10,
        account_admin_users_count: 1
      },
      levels: %{
        empty: %{
          admins: 1,
          users: 0,
          service_accounts: 0,
          sites: 2,
          gateways: 0,
          resources: 1,
          groups: 1,
          policies: 0,
          clients: 0
        },
        light: %{
          admins: 1,
          users: 2,
          service_accounts: 2,
          sites: 4,
          gateways: 2,
          resources: 8,
          groups: 6,
          policies: 8,
          clients: 8
        },
        heavy: %{
          admins: 1,
          users: 5,
          service_accounts: 8,
          sites: 8,
          gateways: 12,
          resources: 24,
          groups: 20,
          policies: 32,
          clients: 18
        }
      }
    },
    team: %{
      product_name: "Team",
      support_type: "email",
      features: %{
        policy_conditions: true,
        traffic_filters: true,
        idp_sync: false,
        rest_api: false,
        internet_resource: true
      },
      limits: %{
        users_count: nil,
        monthly_active_users_count: nil,
        service_accounts_count: 100,
        sites_count: 100,
        account_admin_users_count: 10
      },
      levels: %{
        empty: %{
          admins: 1,
          users: 0,
          service_accounts: 0,
          sites: 2,
          gateways: 0,
          resources: 1,
          groups: 1,
          policies: 0,
          clients: 0
        },
        light: %{
          admins: 2,
          users: 30,
          service_accounts: 12,
          sites: 12,
          gateways: 24,
          resources: 30,
          groups: 24,
          policies: 48,
          clients: 48
        },
        heavy: %{
          admins: 8,
          users: 450,
          service_accounts: 80,
          sites: 80,
          gateways: 240,
          resources: 120,
          groups: 180,
          policies: 260,
          clients: 700
        }
      }
    },
    enterprise: %{
      product_name: "Enterprise",
      support_type: "email_and_slack",
      features: %{
        policy_conditions: true,
        traffic_filters: true,
        idp_sync: true,
        rest_api: true,
        internet_resource: true
      },
      limits: %{
        users_count: nil,
        monthly_active_users_count: nil,
        service_accounts_count: nil,
        sites_count: nil,
        account_admin_users_count: nil
      },
      levels: %{
        empty: %{
          admins: 1,
          users: 0,
          service_accounts: 0,
          sites: 2,
          gateways: 0,
          resources: 1,
          groups: 1,
          policies: 0,
          clients: 0
        },
        light: %{
          admins: 5,
          users: 150,
          service_accounts: 40,
          sites: 8,
          gateways: 24,
          resources: 60,
          groups: 120,
          policies: 160,
          clients: 220
        },
        heavy: %{
          admins: 25,
          users: 2500,
          service_accounts: 250,
          sites: 24,
          gateways: 120,
          resources: 350,
          groups: 1800,
          policies: 900,
          clients: 3200
        }
      }
    }
  }

  def plan_spec(plan) when is_binary(plan),
    do: plan |> String.downcase() |> String.to_existing_atom() |> plan_spec()

  def plan_spec(plan) when is_atom(plan), do: Map.fetch!(@plan_specs, plan)

  def run(plan, level, opts \\ []) do
    plan = normalize_plan!(plan)
    level = normalize_level!(level)
    spec = plan_spec(plan)

    Repo.transaction(fn ->
      base_slug = normalize_slug(opts[:slug] || Atom.to_string(plan))
      final_slug = resolve_slug(base_slug, Keyword.get(opts, :new_slug, false))

      unless Keyword.get(opts, :new_slug, false) do
        replace_existing_account(final_slug)
      end

      account_name = build_account_name(spec.product_name, final_slug)
      email = "billing+#{final_slug}@#{@support_email_domain}"

      state =
        create_baseline_account(%{
          slug: final_slug,
          name: account_name,
          legal_name: account_name,
          spec: spec,
          billing_email: email
        })

      state =
        state
        |> populate_additional_actors(spec.levels[level])
        |> populate_additional_sites(spec.levels[level])
        |> populate_additional_resources(spec.levels[level], spec)
        |> populate_additional_groups(spec.levels[level])
        |> populate_memberships(spec.levels[level])
        |> populate_policies(spec.levels[level], spec)
        |> populate_gateways(spec.levels[level])
        |> populate_clients(spec.levels[level], spec)

      build_summary(state.account, plan, level)
    end)
  end

  def main(argv) do
    argv =
      case argv do
        ["--" | rest] -> rest
        other -> other
      end

    {opts, _, invalid} =
      OptionParser.parse(argv,
        strict: [plan: :string, level: :string, slug: :string, new_slug: :boolean]
      )

    if invalid != [] do
      raise ArgumentError, "invalid options: #{inspect(invalid)}"
    end

    plan = Keyword.get(opts, :plan, "starter")
    level = Keyword.get(opts, :level, "empty")

    run(plan, level, opts)
  end

  def runtime_argv do
    system_argv = System.argv()
    plain_argv = Enum.map(:init.get_plain_arguments(), &List.to_string/1)

    cond do
      option_argv?(system_argv) -> system_argv
      option_argv?(plain_argv) -> plain_argv
      true -> system_argv
    end
  end

  def ensure_runtime_started do
    for app <- [:crypto, :ssl, :postgrex, :ecto, :ecto_sql] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    unless Process.whereis(Portal.Repo) do
      {:ok, _pid} = Portal.Repo.start_link()
    end

    unless Process.whereis(Portal.Repo.Replica) do
      {:ok, _pid} = Portal.Repo.Replica.start_link()
    end

    :ok
  end

  defp normalize_plan!(plan) when is_binary(plan) do
    plan
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> raise ArgumentError, "unknown plan #{inspect(plan)}"
  end

  defp normalize_plan!(plan) when is_atom(plan) do
    if Map.has_key?(@plan_specs, plan) do
      plan
    else
      raise ArgumentError, "unknown plan #{inspect(plan)}"
    end
  end

  defp normalize_level!(level) when is_binary(level) do
    level
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> raise ArgumentError, "unknown level #{inspect(level)}"
  end

  defp normalize_level!(level) when level in [:empty, :light, :heavy], do: level
  defp normalize_level!(level), do: raise(ArgumentError, "unknown level #{inspect(level)}")

  defp option_argv?(argv) when is_list(argv) do
    Enum.any?(argv, &String.starts_with?(&1, "--"))
  end

  defp normalize_slug(slug) do
    slug
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.trim("_")
  end

  defp resolve_slug(base_slug, true) do
    existing =
      from(a in Account,
        where: a.slug == ^base_slug or like(a.slug, ^"#{base_slug}_%"),
        select: a.slug
      )
      |> Repo.all()
      |> MapSet.new()

    cond do
      not MapSet.member?(existing, base_slug) ->
        base_slug

      true ->
        Stream.iterate(1, &(&1 + 1))
        |> Enum.find_value(fn index ->
          candidate = "#{base_slug}_#{index}"
          if MapSet.member?(existing, candidate), do: nil, else: candidate
        end)
    end
  end

  defp resolve_slug(base_slug, false), do: base_slug

  defp replace_existing_account(slug) do
    case existing_account_id_by_slug(slug) do
      nil ->
        :ok

      account_id ->
        Repo.query!("DELETE FROM accounts WHERE id = $1", [account_id])
        :ok
    end
  end

  defp create_baseline_account(attrs) do
    spec = attrs.spec
    now = DateTime.utc_now()
    account_id = Ecto.UUID.generate()
    account_columns = account_columns()

    metadata = %{
      stripe: %{
        billing_email: attrs.billing_email,
        product_name: spec.product_name,
        support_type: spec.support_type
      }
    }

    account_attrs =
      %{
        id: account_id,
        name: attrs.name,
        legal_name: attrs.legal_name,
        slug: attrs.slug,
        features: spec.features,
        limits: spec.limits,
        config: %{},
        metadata: metadata,
        inserted_at: now,
        updated_at: now
      }
      |> maybe_put_account_key(account_columns)

    insert_account(account_columns, account_attrs)

    account = %Account{
      id: account_id,
      name: attrs.name,
      legal_name: attrs.legal_name,
      slug: attrs.slug,
      features: struct(Portal.Accounts.Features, spec.features),
      limits: struct(Portal.Accounts.Limits, spec.limits),
      metadata: %Portal.Account.Metadata{
        stripe: struct(Portal.Account.Metadata.Stripe, metadata.stripe)
      },
      inserted_at: now,
      updated_at: now
    }

    everyone_group = create_group(account, %{name: "Everyone", type: :managed})
    email_provider = create_email_provider(account)

    admin_actor =
      create_actor(account, :account_admin_user, "Admin 1", email_for(account.slug, "admin-1"))

    default_site = create_site(account, "Default Site", :account)
    internet_site = create_site(account, "Internet", :system)
    internet_resource = create_resource(account, internet_site, 1, :internet, spec)

    %{
      account: account,
      spec: spec,
      email_provider: email_provider,
      everyone_group: everyone_group,
      actors: %{admins: [admin_actor], users: [], service_accounts: []},
      sites: %{account_sites: [default_site], internet_site: internet_site},
      resources: %{internet: internet_resource, managed: []},
      groups: [everyone_group],
      policies: [],
      gateways: [],
      clients: [],
      client_tokens: %{},
      gateway_tokens: %{}
    }
  end

  defp populate_additional_actors(state, targets) do
    admin_count = max(targets.admins - length(state.actors.admins), 0)
    user_count = max(targets.users - length(state.actors.users), 0)
    service_count = max(targets.service_accounts - length(state.actors.service_accounts), 0)

    admins =
      for index <- positive_range(admin_count) do
        sequence = length(state.actors.admins) + index

        create_actor(
          state.account,
          :account_admin_user,
          "Admin #{sequence}",
          email_for(state.account.slug, "admin-#{sequence}")
        )
      end

    users =
      for index <- positive_range(user_count) do
        sequence = length(state.actors.users) + index

        create_actor(
          state.account,
          :account_user,
          "User #{sequence}",
          email_for(state.account.slug, "user-#{sequence}")
        )
      end

    service_accounts =
      for index <- positive_range(service_count) do
        sequence = length(state.actors.service_accounts) + index
        create_actor(state.account, :service_account, "Service Account #{sequence}", nil)
      end

    put_in(state.actors.admins, state.actors.admins ++ admins)
    |> put_in([:actors, :users], state.actors.users ++ users)
    |> put_in([:actors, :service_accounts], state.actors.service_accounts ++ service_accounts)
  end

  defp populate_additional_sites(state, targets) do
    current_total = length(state.sites.account_sites) + 1
    additional_count = max(targets.sites - current_total, 0)

    new_sites =
      for index <- positive_range(additional_count) do
        sequence = length(state.sites.account_sites) + index
        create_site(state.account, "Site #{sequence}", :account)
      end

    put_in(state.sites.account_sites, state.sites.account_sites ++ new_sites)
  end

  defp populate_additional_resources(state, targets, spec) do
    current_total = length(state.resources.managed) + 1
    additional_count = max(targets.resources - current_total, 0)

    filtered_count =
      subset_count(
        additional_count,
        resource_filter_ratio(targets),
        spec.features.traffic_filters
      )

    new_resources =
      for index <- positive_range(additional_count) do
        site =
          Enum.at(state.sites.account_sites, rem(index - 1, length(state.sites.account_sites)))

        resource_type = resource_type_for(index)
        resource_index = length(state.resources.managed) + index

        create_resource(
          state.account,
          site,
          resource_index,
          resource_type,
          spec,
          index <= filtered_count
        )
      end

    put_in(state.resources.managed, state.resources.managed ++ new_resources)
  end

  defp populate_additional_groups(state, targets) do
    additional_count = max(targets.groups - length(state.groups), 0)

    new_groups =
      for index <- positive_range(additional_count) do
        sequence = length(state.groups) + index
        create_group(state.account, %{name: "Group #{sequence}", type: :static})
      end

    update_in(state.groups, &(&1 ++ new_groups))
  end

  defp populate_memberships(state, targets) do
    actors = state.actors.admins ++ state.actors.users ++ state.actors.service_accounts
    assignable_groups = Enum.reject(state.groups, &(&1.id == state.everyone_group.id))

    desired_memberships =
      cond do
        assignable_groups == [] or actors == [] ->
          []

        true ->
          memberships_per_actor = memberships_per_actor(targets)

          actors
          |> Enum.with_index()
          |> Enum.flat_map(fn {actor, actor_index} ->
            1..memberships_per_actor
            |> Enum.map(fn offset ->
              group =
                Enum.at(
                  assignable_groups,
                  rem(actor_index + offset - 1, length(assignable_groups))
                )

              {actor.id, group.id}
            end)
          end)
          |> Enum.uniq()
      end

    memberships =
      Enum.map(desired_memberships, fn {actor_id, group_id} ->
        %{
          account_id: state.account.id,
          actor_id: actor_id,
          group_id: group_id
        }
      end)

    if memberships != [] do
      Repo.insert_all(Membership, memberships, on_conflict: :nothing)
    end

    state
  end

  defp populate_policies(state, targets, spec) do
    additional_count = max(targets.policies - length(state.policies), 0)
    groups = Enum.reject(state.groups, &(&1.id == state.everyone_group.id))
    resources = state.resources.managed

    condition_count =
      subset_count(
        additional_count,
        policy_condition_ratio(targets),
        spec.features.policy_conditions
      )

    new_policies =
      if groups == [] or resources == [] do
        []
      else
        for index <- positive_range(additional_count) do
          group = Enum.at(groups, rem(index - 1, length(groups)))
          resource = Enum.at(resources, rem(index - 1, length(resources)))

          create_policy(
            state.account,
            group,
            resource,
            index,
            spec,
            index <= condition_count,
            state.email_provider.id
          )
        end
      end

    update_in(state.policies, &(&1 ++ new_policies))
  end

  defp populate_gateways(state, targets) do
    additional_count = max(targets.gateways - length(state.gateways), 0)

    if state.sites.account_sites == [] do
      state
    else
      Enum.reduce(positive_range(additional_count), state, fn index, acc ->
        site = Enum.at(acc.sites.account_sites, rem(index - 1, length(acc.sites.account_sites)))
        {gateway, acc} = create_gateway(acc, site, index)
        update_in(acc.gateways, &(&1 ++ [gateway]))
      end)
    end
  end

  defp populate_clients(state, targets, spec) do
    additional_count = max(targets.clients - length(state.clients), 0)
    actors = client_actors(state)
    verified_count = subset_count(additional_count, 0.5, spec.features.policy_conditions)

    if actors == [] do
      state
    else
      Enum.reduce(positive_range(additional_count), state, fn index, acc ->
        actor = Enum.at(actors, rem(index - 1, length(actors)))
        verified? = index <= verified_count
        {client, acc} = create_client(acc, actor, index, verified?)
        update_in(acc.clients, &(&1 ++ [client]))
      end)
    end
  end

  defp create_group(account, attrs) do
    %Group{}
    |> cast(attrs, [:name, :type])
    |> put_change(:account_id, account.id)
    |> validate_required([:name, :account_id, :type])
    |> Group.changeset()
    |> Repo.insert!()
  end

  defp create_actor(account, type, name, email) do
    attrs =
      %{
        account_id: account.id,
        type: type,
        name: name,
        email: email,
        allow_email_otp_sign_in: type != :service_account,
        password_hash:
          if(type == :service_account, do: nil, else: Crypto.hash(:argon2, @default_password))
      }

    %Actor{}
    |> cast(attrs, [:account_id, :type, :name, :email, :allow_email_otp_sign_in, :password_hash])
    |> Actor.changeset()
    |> Repo.insert!()
  end

  defp create_site(account, name, managed_by) do
    %Site{account_id: account.id, managed_by: managed_by}
    |> cast(%{name: name, managed_by: managed_by}, [:name, :managed_by])
    |> validate_required([:name, :managed_by])
    |> Site.changeset()
    |> Repo.insert!()
  end

  defp create_resource(account, site, index, type, spec, filtered? \\ false)

  defp create_resource(account, site, _index, :internet, _spec, _filtered?) do
    Repo.insert!(%Resource{
      account_id: account.id,
      site_id: site.id,
      type: :internet,
      name: "Internet"
    })
  end

  defp create_resource(account, site, index, type, _spec, filtered?) do
    attrs =
      resource_attrs(type, index)
      |> Map.put(:name, "Resource #{index}")
      |> maybe_put_filters(filtered?)

    Repo.insert!(struct(Resource, Map.merge(attrs, %{account_id: account.id, site_id: site.id})))
  end

  defp resource_attrs(:dns, index) do
    %{
      type: :dns,
      address: "app#{index}.dev-population.test",
      address_description: "DNS resource #{index}",
      ip_stack: :dual
    }
  end

  defp resource_attrs(:ip, index) do
    third = rem(index, 200) + 1
    fourth = rem(index * 7, 200) + 1
    %{type: :ip, address: "192.0.#{third}.#{fourth}", address_description: "IP resource #{index}"}
  end

  defp resource_attrs(:cidr, index) do
    third = rem(index, 200)
    %{type: :cidr, address: "172.20.#{third}.0/24", address_description: "CIDR resource #{index}"}
  end

  defp maybe_put_filters(attrs, false), do: attrs

  defp maybe_put_filters(attrs, true) do
    Map.put(attrs, :filters, [%Resource.Filter{protocol: :tcp, ports: []}])
  end

  defp resource_type_for(index) do
    case rem(index, 3) do
      0 -> :dns
      1 -> :ip
      _ -> :cidr
    end
  end

  defp create_policy(account, group, resource, index, _spec, with_conditions?, email_provider_id) do
    attrs =
      %{
        account_id: account.id,
        group_id: group.id,
        resource_id: resource.id,
        description: "Policy #{index}"
      }
      |> maybe_put_policy_conditions(with_conditions?, index, email_provider_id)

    %Policy{}
    |> cast(attrs, [:account_id, :group_id, :resource_id, :description])
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset(&1, &2, 0))
    |> Policy.changeset()
    |> Repo.insert!()
  end

  defp maybe_put_policy_conditions(attrs, false, _index, _provider_id), do: attrs

  defp maybe_put_policy_conditions(attrs, true, index, provider_id) do
    condition =
      case rem(index, 3) do
        0 ->
          %{property: :remote_ip_location_region, operator: :is_in, values: ["US", "CA"]}

        1 ->
          %{property: :client_verified, operator: :is, values: ["true"]}

        _ ->
          %{property: :auth_provider_id, operator: :is_in, values: [provider_id]}
      end

    Map.put(attrs, :conditions, [condition])
  end

  defp create_gateway(state, site, index) do
    gateway =
      %Device{}
      |> cast(
        %{
          name: "Gateway #{site.name}-#{index}",
          firezone_id: "#{state.account.slug}-gw-#{site.id}-#{index}"
        },
        [:name, :firezone_id]
      )
      |> put_change(:type, :gateway)
      |> put_change(:account_id, state.account.id)
      |> put_change(:site_id, site.id)
      |> Device.changeset()
      |> Repo.insert!()

    {token, state} =
      case Map.fetch(state.gateway_tokens, site.id) do
        {:ok, token} ->
          {token, state}

        :error ->
          token = create_gateway_token(site, state.account)
          {token, put_in(state.gateway_tokens[site.id], token)}
      end

    %GatewaySession{}
    |> cast(
      %{
        account_id: state.account.id,
        device_id: gateway.id,
        gateway_token_id: token.id,
        public_key: "gateway-public-key-#{index}",
        user_agent: @gateway_user_agent,
        remote_ip: @default_gateway_remote_ip,
        remote_ip_location_region: "US-CA",
        remote_ip_location_city: "San Francisco",
        remote_ip_location_lat: 37.7749,
        remote_ip_location_lon: -122.4194,
        version: "1.4.0"
      },
      [
        :account_id,
        :device_id,
        :gateway_token_id,
        :public_key,
        :user_agent,
        :remote_ip,
        :remote_ip_location_region,
        :remote_ip_location_city,
        :remote_ip_location_lat,
        :remote_ip_location_lon,
        :version
      ]
    )
    |> GatewaySession.changeset()
    |> Repo.insert!()

    {gateway, state}
  end

  defp create_client(state, actor, index, verified?) do
    {token, state} =
      case Map.fetch(state.client_tokens, actor.id) do
        {:ok, token} ->
          {token, state}

        :error ->
          token = create_client_token(actor, state.email_provider, state.account)
          {token, put_in(state.client_tokens[actor.id], token)}
      end

    client =
      %Device{}
      |> cast(
        %{
          name: "Client #{index}",
          firezone_id: "#{state.account.slug}-client-#{actor.id}-#{index}",
          device_uuid: Ecto.UUID.generate(),
          device_serial: "SN#{index}",
          identifier_for_vendor: "ifv-#{index}",
          verified_at: if(verified?, do: DateTime.utc_now(), else: nil)
        },
        [
          :name,
          :firezone_id,
          :device_uuid,
          :device_serial,
          :identifier_for_vendor,
          :verified_at
        ]
      )
      |> put_change(:type, :client)
      |> put_change(:account_id, state.account.id)
      |> put_change(:actor_id, actor.id)
      |> Device.changeset()
      |> Repo.insert!()

    %ClientSession{}
    |> cast(
      %{
        account_id: state.account.id,
        device_id: client.id,
        client_token_id: token.id,
        public_key: "client-public-key-#{index}",
        user_agent: @default_user_agent,
        remote_ip: @default_client_remote_ip,
        remote_ip_location_region: "US",
        remote_ip_location_city: "New York",
        remote_ip_location_lat: 40.7128,
        remote_ip_location_lon: -74.0060,
        version: "1.4.0"
      },
      [
        :account_id,
        :device_id,
        :client_token_id,
        :public_key,
        :user_agent,
        :remote_ip,
        :remote_ip_location_region,
        :remote_ip_location_city,
        :remote_ip_location_lat,
        :remote_ip_location_lon,
        :version
      ]
    )
    |> ClientSession.changeset()
    |> Repo.insert!()

    {client, state}
  end

  defp create_email_provider(account) do
    provider_id = Ecto.UUID.generate()

    %AuthProvider{}
    |> cast(%{id: provider_id, account_id: account.id, type: :email_otp}, [
      :id,
      :account_id,
      :type
    ])
    |> AuthProvider.changeset()
    |> Repo.insert!()

    %EmailOTP.AuthProvider{}
    |> cast(
      %{
        id: provider_id,
        account_id: account.id,
        name: "Email (OTP)",
        context: :clients_and_portal
      },
      [:id, :account_id, :name, :context]
    )
    |> EmailOTP.AuthProvider.changeset()
    |> Repo.insert!()
  end

  defp create_gateway_token(site, account) do
    subject = subject_for(account)
    {:ok, token} = Authentication.create_gateway_token(site, subject)
    token
  end

  defp create_client_token(%Actor{type: :service_account} = actor, _provider, account) do
    {:ok, token} =
      Authentication.create_headless_client_token(
        actor,
        %{expires_at: DateTime.add(DateTime.utc_now(), 30, :day)},
        subject_for(account)
      )

    token
  end

  defp create_client_token(actor, provider, _account) do
    {:ok, token} =
      Authentication.create_gui_client_token(%{
        account_id: actor.account_id,
        actor_id: actor.id,
        auth_provider_id: provider.id,
        expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
      })

    token
  end

  defp subject_for(account) do
    %Subject{
      account: account,
      actor: %Actor{
        id: Ecto.UUID.generate(),
        account_id: account.id,
        type: :account_admin_user,
        name: "Population Script"
      },
      credential: %Credential{id: Ecto.UUID.generate(), type: :token},
      expires_at: DateTime.add(DateTime.utc_now(), 1, :hour),
      context: %Context{
        type: :client,
        remote_ip: {127, 0, 0, 1},
        user_agent: "account-population/1.0"
      }
    }
  end

  defp client_actors(state) do
    service_accounts = state.actors.service_accounts
    people = state.actors.admins ++ state.actors.users

    people ++ service_accounts ++ service_accounts
  end

  defp resource_filter_ratio(%{resources: resources}) when resources >= 100, do: 0.5
  defp resource_filter_ratio(_targets), do: 0.3

  defp policy_condition_ratio(%{policies: policies}) when policies >= 100, do: 0.4
  defp policy_condition_ratio(_targets), do: 0.25

  defp memberships_per_actor(%{groups: groups}) when groups >= 100, do: 4
  defp memberships_per_actor(%{groups: groups}) when groups >= 20, do: 3
  defp memberships_per_actor(_targets), do: 2

  defp subset_count(_total, _ratio, false), do: 0
  defp subset_count(total, ratio, true), do: floor(total * ratio)

  defp positive_range(count) when count <= 0, do: []
  defp positive_range(count), do: 1..count

  defp build_account_name(product_name, slug) do
    suffix =
      slug
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    "#{product_name} #{suffix}"
  end

  defp email_for(slug, name) do
    sanitized_slug = String.replace(slug, "_", "-")
    "#{name}@#{sanitized_slug}.#{@support_email_domain}"
  end

  defp build_summary(account, plan, level) do
    admin_email =
      from(a in Actor,
        where:
          a.account_id == ^account.id and a.type == :account_admin_user and not is_nil(a.email),
        order_by: [asc: a.inserted_at, asc: a.email],
        select: a.email,
        limit: 1
      )
      |> Repo.one()

    counts = %{
      admins: count_actors(account.id, :account_admin_user),
      users: count_actors(account.id, :account_user),
      service_accounts: count_actors(account.id, :service_account),
      groups: count_records(Group, account.id),
      policies: count_records(Policy, account.id),
      resources: count_records(Resource, account.id),
      sites: count_records(Site, account.id),
      gateways: count_device_type(account.id, :gateway),
      clients: count_device_type(account.id, :client)
    }

    %{
      account_id: account.id,
      slug: account.slug,
      name: account.name,
      plan: plan,
      level: level,
      admin_email: admin_email,
      counts: counts
    }
  end

  defp count_actors(account_id, type) do
    from(a in Actor, where: a.account_id == ^account_id and a.type == ^type)
    |> Repo.aggregate(:count)
  end

  defp count_records(schema, account_id) do
    from(s in schema, where: field(s, :account_id) == ^account_id)
    |> Repo.aggregate(:count)
  end

  defp count_device_type(account_id, type) do
    from(d in Device, where: d.account_id == ^account_id and d.type == ^type)
    |> Repo.aggregate(:count)
  end

  defp account_columns do
    Repo.query!(
      "SELECT column_name FROM information_schema.columns WHERE table_name = 'accounts'",
      []
    ).rows
    |> List.flatten()
    |> MapSet.new()
  end

  defp maybe_put_account_key(attrs, columns) do
    if MapSet.member?(columns, "key") do
      Map.put(attrs, :key, String.slice(attrs.slug <> "000000", 0, 6))
    else
      attrs
    end
  end

  defp insert_account(columns, attrs) do
    fields =
      [
        :id,
        :name,
        :legal_name,
        :slug,
        :features,
        :limits,
        :config,
        :metadata,
        :inserted_at,
        :updated_at,
        :key
      ]
      |> Enum.filter(&MapSet.member?(columns, Atom.to_string(&1)))

    placeholders =
      1..length(fields)
      |> Enum.map_join(", ", &"$#{&1}")

    query =
      "INSERT INTO accounts (#{Enum.map_join(fields, ", ", &Atom.to_string/1)}) VALUES (#{placeholders})"

    values =
      Enum.map(fields, fn
        :id -> Ecto.UUID.dump!(attrs.id)
        field -> Map.fetch!(attrs, field)
      end)

    Repo.query!(query, values)
  end

  defp existing_account_id_by_slug(slug) do
    case Repo.query!("SELECT id FROM accounts WHERE slug = $1 LIMIT 1", [slug]).rows do
      [[id]] -> id
      [] -> nil
    end
  end
end
