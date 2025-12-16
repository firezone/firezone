defmodule Domain.Repo.Seeds do
  @moduledoc """
  Seeds the database with initial data.
  """
  import Ecto.Changeset

  alias Domain.{
    Repo,
    Auth,
    AuthProvider,
    Account,
    Actor,
    Client,
    Crypto,
    EmailOTP,
    Entra,
    ExternalIdentity,
    PolicyAuthorization,
    Gateway,
    Google,
    Group,
    Membership,
    NameGenerator,
    OIDC,
    Policy,
    Relay,
    Resource,
    Site,
    ClientToken,
    Userpass
  }

  # Populate these in your .env
  defp google_idp_id do
    System.get_env("GOOGLE_IDP_ID", "dummy")
  end

  defp entra_idp_id do
    System.get_env("ENTRA_IDP_ID", "dummy")
  end

  defp entra_tenant_id do
    System.get_env("ENTRA_TENANT_ID", "dummy")
  end

  # Helper function to create auth providers with the new structure
  defp create_auth_provider(provider_module, attrs, subject) do
    provider_id = Ecto.UUID.generate()
    IO.inspect(provider_module, label: "Provider module being passed")
    type = AuthProvider.type!(provider_module)
    # Convert type to atom if it's a string
    type = if is_binary(type), do: String.to_existing_atom(type), else: type

    # First create the base auth_provider record using Repo directly
    {:ok, _base_provider} =
      Repo.insert(%AuthProvider{
        id: provider_id,
        account_id: subject.account.id,
        type: type
      })

    # Then create the provider-specific record using Repo directly (seeds don't need authorization)
    attrs_with_id =
      attrs
      |> Map.put(:id, provider_id)
      |> Map.put(:account_id, subject.account.id)

    changeset = struct(provider_module, attrs_with_id) |> Ecto.Changeset.change()

    Repo.insert(changeset)
  end

  # Helper function to create resource directly without context module
  defp create_resource(attrs, subject) do
    # Create the resource
    resource =
      %Resource{
        account_id: subject.account.id,
        type: attrs[:type] || attrs["type"],
        name: attrs[:name] || attrs["name"],
        address: attrs[:address] || attrs["address"],
        address_description: attrs[:address_description] || attrs["address_description"],
        filters: attrs[:filters] || attrs["filters"] || [],
        site_id: attrs[:site_id] || attrs["site_id"]
      }
      |> Repo.insert!()

    {:ok, resource}
  end

  # Allocate tunnel IP addresses for clients/gateways
  # Uses monotonic counter for sequential unique addresses
  # Must be called AFTER the client/gateway is created, passing its ID
  defp create_tunnel_ip_addresses(account_id, opts) do
    client_id = Keyword.get(opts, :client_id)
    gateway_id = Keyword.get(opts, :gateway_id)

    # Offset by 1 since unique_integer starts at 0
    offset = System.unique_integer([:positive, :monotonic]) + 1

    # CGNAT range: 100.64.0.0/11 - offset into last two octets
    # Using offset directly, max 8190 addresses (32 * 256 - 2)
    ipv4_third = rem(div(offset, 256), 32)
    ipv4_fourth = rem(offset, 256)

    # fd00:2021:1111::/107 range - offset into last word
    # Using offset directly for simplicity
    ipv6_w8 = offset

    ipv4 = {100, 64, ipv4_third, ipv4_fourth}
    ipv6 = {0xFD00, 0x2021, 0x1111, 0, 0, 0, 0, ipv6_w8}

    # Create address records with client/gateway FK
    %Domain.IPv4Address{
      account_id: account_id,
      address: ipv4,
      client_id: client_id,
      gateway_id: gateway_id
    }
    |> Repo.insert!()

    %Domain.IPv6Address{
      account_id: account_id,
      address: ipv6,
      client_id: client_id,
      gateway_id: gateway_id
    }
    |> Repo.insert!()

    :ok
  end

  # Helper function to create gateway directly without context module
  defp create_gateway(attrs, context) do
    # Extract version from user agent
    version =
      context.user_agent
      |> String.split(" connlib/")
      |> List.last()
      |> String.split(" ")
      |> List.first()

    # Get the site to get the account_id
    site_id = attrs["site_id"] || attrs[:site_id]
    site = Repo.get_by!(Site, id: site_id)
    external_id = attrs["external_id"] || attrs[:external_id]

    # First create the gateway
    gateway =
      %Gateway{
        site_id: site_id,
        account_id: site.account_id,
        name: attrs["name"] || attrs[:name],
        external_id: external_id,
        public_key: attrs["public_key"] || attrs[:public_key],
        last_seen_user_agent: context.user_agent,
        last_seen_remote_ip: context.remote_ip,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now()
      }
      |> Repo.insert!()

    # Then create tunnel IP addresses with gateway FK
    create_tunnel_ip_addresses(site.account_id, gateway_id: gateway.id)

    {:ok, Repo.preload(gateway, [:ipv4_address, :ipv6_address])}
  end

  # Helper function to create client directly without context module
  defp create_client(attrs, subject, user_agent) do
    # Extract version from user agent (e.g., "iOS/12.7 (iPhone) connlib/0.7.412" -> "0.7.412")
    version =
      user_agent |> String.split(" connlib/") |> List.last() |> String.split(" ") |> List.first()

    external_id = attrs["external_id"] || attrs[:external_id]

    # First create the client
    client =
      %Client{
        account_id: subject.account.id,
        actor_id: subject.actor.id,
        name: attrs["name"] || attrs[:name],
        external_id: external_id,
        public_key: attrs["public_key"] || attrs[:public_key],
        identifier_for_vendor: attrs["identifier_for_vendor"] || attrs[:identifier_for_vendor],
        device_uuid: attrs["device_uuid"] || attrs[:device_uuid],
        device_serial: attrs["device_serial"] || attrs[:device_serial],
        last_seen_user_agent: user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now()
      }
      |> Repo.insert!()

    # Then create tunnel IP addresses with client FK
    create_tunnel_ip_addresses(subject.account.id, client_id: client.id)

    {:ok, Repo.preload(client, [:ipv4_address, :ipv6_address])}
  end

  def seed do
    # Seeds can be run both with MIX_ENV=prod and MIX_ENV=test, for test env we don't have
    # an adapter configured and creation of email provider will fail, so we will override it here.
    System.put_env("OUTBOUND_EMAIL_ADAPTER", "Elixir.Swoosh.Adapters.Mailgun")

    # Ensure seeds are deterministic
    :rand.seed(:exsss, {1, 2, 3})

    # This function is used to update fields if STATIC_SEEDS is set,
    # which helps with static docker-compose environment for local development.
    maybe_repo_update = fn resource, values ->
      if System.get_env("STATIC_SEEDS") == "true" do
        changeset = Ecto.Changeset.change(resource, values)

        # RelayToken and GatewayToken have virtual fields that cannot be persisted
        case resource do
          %Domain.RelayToken{id: id} when not is_nil(id) ->
            import Ecto.Query

            # Filter out virtual fields that can't be persisted
            virtual_fields = [:secret_fragment]

            db_changes = Map.drop(changeset.changes, virtual_fields)

            from(rt in Domain.RelayToken, where: rt.id == ^id)
            |> Repo.update_all(set: Enum.to_list(db_changes))

            struct(resource, changeset.changes)

          %Domain.GatewayToken{account_id: account_id, id: id}
          when not is_nil(account_id) and not is_nil(id) ->
            import Ecto.Query

            # Filter out virtual fields that can't be persisted
            virtual_fields = [:secret_fragment]

            db_changes = Map.drop(changeset.changes, virtual_fields)

            from(gt in Domain.GatewayToken,
              where: gt.account_id == ^account_id,
              where: gt.id == ^id
            )
            |> Repo.update_all(set: Enum.to_list(db_changes))

            struct(resource, changeset.changes)

          _ ->
            Repo.update!(changeset)
        end
      else
        resource
      end
    end

    account =
      %Account{}
      |> cast(
        %{
          name: "Firezone Account",
          legal_name: "Firezone Account",
          slug: "firezone",
          config: %{
            search_domain: "httpbin.search.test"
          }
        },
        [:name, :legal_name, :slug]
      )
      |> cast_embed(:config)
      |> Repo.insert!()

    account =
      account
      |> Ecto.Changeset.change(
        features: %{
          policy_conditions: true,
          multi_site_resources: true,
          traffic_filters: true,
          idp_sync: true,
          rest_api: true,
          internet_resource: true
        }
      )
      |> Repo.update!()

    account =
      maybe_repo_update.(account,
        id: Ecto.UUID.cast!("c89bcc8c-9392-4dae-a40d-888aef6d28e0"),
        metadata: %{
          stripe: %{
            customer_id: "cus_PZKIfcHB6SSBA4",
            subscription_id: "sub_1OkGm2ADeNU9NGxvbrCCw6m3",
            product_name: "Enterprise",
            billing_email: "fin@firez.one",
            support_type: "email"
          }
        },
        limits: %{
          users_count: 15,
          monthly_active_users_count: 10,
          service_accounts_count: 10,
          sites_count: 3,
          account_admin_users_count: 5
        }
      )

    other_account =
      %Account{}
      |> cast(
        %{
          name: "Other Corp Account",
          legal_name: "Other Corp Account",
          slug: "not_firezone"
        },
        [:name, :legal_name, :slug]
      )
      |> Repo.insert!()

    other_account =
      maybe_repo_update.(other_account,
        id: Ecto.UUID.cast!("9b9290bf-e1bc-4dd3-b401-511908262690")
      )

    IO.puts("Created accounts: ")

    for item <- [account, other_account] do
      IO.puts("  #{item.id}: #{item.name}")
    end

    IO.puts("")

    internet_site =
      %Site{
        account_id: account.id,
        name: "Internet",
        managed_by: :system
      }
      |> Repo.insert!()

    other_internet_site =
      %Site{
        account_id: other_account.id,
        name: "Internet",
        managed_by: :system
      }
      |> Repo.insert!()

    # Create internet resources
    _internet_resource =
      %Resource{
        account_id: account.id,
        name: "Internet",
        type: :internet,
        site_id: internet_site.id
      }
      |> Repo.insert!()

    _other_internet_resource =
      %Resource{
        account_id: other_account.id,
        name: "Internet",
        type: :internet,
        site_id: other_internet_site.id
      }
      |> Repo.insert!()

    IO.puts("")

    everyone_group =
      %Group{
        account_id: account.id,
        name: "Everyone",
        type: :managed
      }
      |> Repo.insert!()

    _everyone_group =
      %Group{
        account_id: other_account.id,
        name: "Everyone",
        type: :managed
      }
      |> Repo.insert!()

    # Create auth providers for main account
    system_subject = %Auth.Subject{
      account: account,
      actor: %Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      credential: %Auth.Credential{type: :token, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Auth.Context{type: :client, remote_ip: {127, 0, 0, 1}, user_agent: "seeds/1"}
    }

    {:ok, _email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, system_subject)

    {:ok, userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        system_subject
      )

    {:ok, _oidc_provider} =
      create_auth_provider(
        OIDC.AuthProvider,
        %{
          is_verified: true,
          name: "OIDC",
          issuer: "https://common.auth0.com",
          client_id: "CLIENT_ID",
          client_secret: "CLIENT_SECRET",
          discovery_document_uri: "https://common.auth0.com/.well-known/openid-configuration",
          scope: "openid email profile groups"
        },
        system_subject
      )

    {:ok, _google_provider} =
      create_auth_provider(
        Google.AuthProvider,
        %{
          is_verified: true,
          name: "Google",
          issuer: "https://accounts.google.com",
          domain: "firezone.dev"
        },
        system_subject
      )

    {:ok, _entra_provider} =
      create_auth_provider(
        Entra.AuthProvider,
        %{
          is_verified: true,
          name: "Entra",
          issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
          tenant_id: entra_tenant_id()
        },
        system_subject
      )

    # Create auth providers for other_account
    other_system_subject = %Auth.Subject{
      account: other_account,
      actor: %Actor{type: :system, id: Ecto.UUID.generate(), name: "System"},
      credential: %Auth.Credential{type: :portal_session, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Auth.Context{type: :portal, remote_ip: {127, 0, 0, 1}, user_agent: "seeds/1"}
    }

    {:ok, _other_email_provider} =
      create_auth_provider(EmailOTP.AuthProvider, %{name: "Email OTP"}, other_system_subject)

    {:ok, _other_userpass_provider} =
      create_auth_provider(
        Userpass.AuthProvider,
        %{name: "Username & Password"},
        other_system_subject
      )

    unprivileged_actor_email = "firezone-unprivileged-1@localhost.local"
    admin_actor_email = "firezone@localhost.local"

    {:ok, unprivileged_actor} =
      %Actor{
        account_id: account.id,
        type: :account_user,
        name: "Firezone Unprivileged",
        email: unprivileged_actor_email,
        allow_email_otp_sign_in: true
      }
      |> Repo.insert()

    other_actors_with_emails =
      for i <- 1..10 do
        email = "user-#{i}@localhost.local"

        {:ok, actor} =
          Repo.insert(%Actor{
            account_id: account.id,
            type: :account_user,
            name: "Firezone Unprivileged #{i}",
            email: email
          })

        {actor, email}
      end

    other_actors = Enum.map(other_actors_with_emails, fn {actor, _email} -> actor end)

    {:ok, admin_actor} =
      Repo.insert(%Actor{
        account_id: account.id,
        type: :account_admin_user,
        name: "Firezone Admin",
        email: admin_actor_email,
        allow_email_otp_sign_in: true
      })

    {:ok, service_account_actor} =
      Repo.insert(%Actor{
        account_id: account.id,
        type: :service_account,
        name: "Backup Manager"
      })

    # Set password on actors (no identity needed for userpass/email)
    password_hash = Crypto.hash(:argon2, "Firezone1234")

    unprivileged_actor =
      unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    admin_actor =
      admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    # Create separate OIDC identity (different issuer)
    {:ok, _admin_actor_oidc_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://common.auth0.com",
        idp_id: admin_actor_email,
        name: "Firezone Admin"
      })

    {:ok, _google_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://accounts.google.com",
        idp_id: google_idp_id(),
        name: "Firezone Admin"
      })

    {:ok, _entra_identity} =
      Repo.insert(%ExternalIdentity{
        actor_id: admin_actor.id,
        account_id: account.id,
        issuer: "https://login.microsoftonline.com/#{entra_tenant_id()}/v2.0",
        idp_id: entra_idp_id(),
        name: "Firezone Admin"
      })

    for {actor, email} <- other_actors_with_emails do
      {:ok, identity} =
        Repo.insert(%ExternalIdentity{
          actor_id: actor.id,
          account_id: account.id,
          issuer: "https://common.auth0.com",
          idp_id: email,
          name: actor.name
        })

      context = %Auth.Context{
        type: :client,
        user_agent: "Windows/10.0.22631 seeds/1",
        remote_ip: {172, 28, 0, 100},
        remote_ip_location_region: "UA",
        remote_ip_location_city: "Kyiv",
        remote_ip_location_lat: 50.4333,
        remote_ip_location_lon: 30.5167
      }

      {:ok, token} =
        Repo.insert(%ClientToken{
          auth_provider_id: userpass_provider.id,
          account_id: account.id,
          actor_id: identity.actor_id,
          expires_at: DateTime.utc_now() |> DateTime.add(90, :day),
          secret_nonce: "n",
          secret_fragment: Crypto.random_token(32),
          secret_salt: Crypto.random_token(16),
          secret_hash: "placeholder"
        })

      {:ok, subject} = Auth.build_subject(token, context)

      count = Enum.random([1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 240])

      for i <- 0..count do
        user_agent =
          Enum.random([
            "iOS/12.7 (iPhone) connlib/1.5.0",
            "Android/14 connlib/1.4.1",
            "Windows/10.0.22631 connlib/1.3.412",
            "Ubuntu/22.4.0 connlib/1.2.2"
          ])

        client_name = String.split(user_agent, "/") |> List.first()

        # Create client directly using Repo since context modules are removed
        # Extract version from user agent (e.g., "Ubuntu/22.4.0 connlib/1.2.2" -> "1.2.2")
        version =
          user_agent |> String.split("/") |> List.last() |> String.split(" ") |> List.first()

        # Generate UUID first so we can use it for deterministic tunnel IPs
        external_id = Ecto.UUID.generate()

        # First create the client
        client =
          %Client{
            account_id: subject.account.id,
            actor_id: subject.actor.id,
            name: "My #{client_name} #{i}",
            external_id: external_id,
            public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
            identifier_for_vendor: Ecto.UUID.generate(),
            last_seen_user_agent: user_agent,
            last_seen_remote_ip: subject.context.remote_ip,
            last_seen_version: version,
            last_seen_at: DateTime.utc_now()
          }
          |> Repo.insert!()

        # Then create tunnel IP addresses with client FK
        create_tunnel_ip_addresses(subject.account.id, client_id: client.id)
      end
    end

    # Other Account Users
    other_unprivileged_actor_email = "other-unprivileged-1@localhost.local"
    other_admin_actor_email = "other@localhost.local"

    {:ok, other_unprivileged_actor} =
      Repo.insert(%Actor{
        account_id: other_account.id,
        type: :account_user,
        name: "Other Unprivileged",
        email: other_unprivileged_actor_email
      })

    {:ok, other_admin_actor} =
      Repo.insert(%Actor{
        account_id: other_account.id,
        type: :account_admin_user,
        name: "Other Admin",
        email: other_admin_actor_email
      })

    # Set password on other_account actors (no identity needed for userpass/email)
    password_hash = Crypto.hash(:argon2, "Firezone1234")

    _other_unprivileged_actor =
      other_unprivileged_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    _other_admin_actor =
      other_admin_actor
      |> Ecto.Changeset.change(password_hash: password_hash)
      |> Repo.update!()

    _unprivileged_actor_context = %Auth.Context{
      type: :client,
      user_agent: "iOS/18.1.0 connlib/1.3.5",
      remote_ip: {172, 28, 0, 100},
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4333,
      remote_ip_location_lon: 30.5167
    }

    # Create client token for unprivileged actor so policy authorizations can reference it
    {:ok, unprivileged_client_token} =
      Repo.insert(%ClientToken{
        auth_provider_id: userpass_provider.id,
        account_id: account.id,
        actor_id: unprivileged_actor.id,
        secret_nonce: Ecto.UUID.generate(),
        secret_fragment: Ecto.UUID.generate(),
        secret_salt: Ecto.UUID.generate(),
        secret_hash: Ecto.UUID.generate(),
        expires_at: DateTime.utc_now() |> DateTime.add(7, :day)
      })

    # For seeds, create a system subject for admin operations
    # In real usage, subjects are created during sign-in flow
    admin_subject = %Auth.Subject{
      account: account,
      actor: admin_actor,
      credential: %Auth.Credential{type: :portal_session, id: Ecto.UUID.generate()},
      expires_at: DateTime.utc_now() |> DateTime.add(1, :hour),
      context: %Auth.Context{
        type: :portal,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    unprivileged_subject = %Auth.Subject{
      account: account,
      actor: unprivileged_actor,
      credential: %Auth.Credential{type: :token, id: unprivileged_client_token.id},
      expires_at: unprivileged_client_token.expires_at,
      context: %Auth.Context{
        type: :client,
        remote_ip: {127, 0, 0, 1},
        user_agent: "seeds/1"
      }
    }

    # Create service account token using Auth module for proper handling
    # Use nonce "n" for backwards compatibility with old static seeds
    nonce = "n"

    token_attrs = %{
      account_id: service_account_actor.account_id,
      actor_id: service_account_actor.id,
      secret_nonce: nonce,
      expires_at: DateTime.utc_now() |> DateTime.add(365, :day)
    }

    # Use Auth.create_token which properly sets secret_salt, secret_fragment, and secret_hash
    {:ok, service_account_token} =
      Auth.create_headless_client_token(service_account_actor, token_attrs, admin_subject)

    service_account_token =
      service_account_token
      |> maybe_repo_update.(
        id: Ecto.UUID.cast!("7da7d1cd-111c-44a7-b5ac-4027b9d230e5"),
        secret_salt: "kKKA7dtf3TJk0-1O2D9N1w",
        secret_fragment: "AiIy_6pBk-WLeRAPzzkCFXNqIZKWBs2Ddw_2vgIQvFg",
        secret_hash: "5c1d6795ea1dd08b6f4fd331eeaffc12032ba171d227f328446f2d26b96437e5"
      )

    service_account_actor_encoded_token = nonce <> Auth.encode_fragment!(service_account_token)

    # Email tokens are generated during sign-in flow, not pre-generated
    unprivileged_actor_email_token = "<generated during sign-in>"
    admin_actor_email_token = "<generated during sign-in>"

    IO.puts("Created users: ")

    for {type, login, password, email_token} <- [
          {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
           unprivileged_actor_email_token},
          {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_email_token}
        ] do
      IO.puts(
        "  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)"
      )
    end

    IO.puts("  #{service_account_actor.name} token: #{service_account_actor_encoded_token}")
    IO.puts("")

    {:ok, user_iphone} =
      create_client(
        %{
          name: "FZ User iPhone",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "APPL-#{Ecto.UUID.generate()}"
        },
        unprivileged_subject,
        "iOS/12.7 (iPhone) connlib/0.7.412"
      )

    {:ok, _user_android_phone} =
      create_client(
        %{
          name: "FZ User Android",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          identifier_for_vendor: "GOOG-#{Ecto.UUID.generate()}"
        },
        unprivileged_subject,
        "Android/14 connlib/0.7.412"
      )

    {:ok, _user_windows_laptop} =
      create_client(
        %{
          name: "FZ User Surface",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "WIN-#{Ecto.UUID.generate()}"
        },
        unprivileged_subject,
        "Windows/10.0.22631 connlib/0.7.412"
      )

    {:ok, _user_linux_laptop} =
      create_client(
        %{
          name: "FZ User Rendering Station",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_uuid: "UB-#{Ecto.UUID.generate()}"
        },
        unprivileged_subject,
        "Ubuntu/22.4.0 connlib/0.7.412"
      )

    {:ok, _admin_iphone} =
      create_client(
        %{
          name: "FZ Admin Laptop",
          external_id: Ecto.UUID.generate(),
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
          device_serial: "FVFHF246Q72Z",
          device_uuid: "#{Ecto.UUID.generate()}"
        },
        admin_subject,
        "Mac OS/14.5 connlib/0.7.412"
      )

    IO.puts("Clients created")
    IO.puts("")

    IO.puts("Created Groups: ")

    # Collect all actors for this account
    all_actors = [
      unprivileged_actor,
      admin_actor,
      service_account_actor | other_actors
    ]

    actor_ids = Enum.map(all_actors, & &1.id)
    # Total number of actors
    max_members = length(actor_ids)

    # Create groups in chunks and collect their IDs
    group_ids =
      1..20
      # Process in chunks to manage memory
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn chunk ->
        group_attrs =
          Enum.map(chunk, fn i ->
            %{
              name: "#{NameGenerator.generate_slug()}-#{i}",
              type: :static,
              account_id: admin_subject.account.id,
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }
          end)

        {_, inserted_groups} =
          Repo.insert_all(
            Group,
            group_attrs,
            returning: [:id]
          )

        Enum.map(inserted_groups, & &1.id)
      end)

    # Create memberships
    memberships =
      group_ids
      |> Enum.chunk_every(1000)
      |> Enum.flat_map(fn group_chunk ->
        Enum.flat_map(group_chunk, fn group_id ->
          # Determine random number of members (1 to max_members)
          num_members = :rand.uniform(max_members)

          # Select random actor IDs
          member_ids =
            actor_ids
            # Uses seeded random
            |> Enum.shuffle()
            |> Enum.take(num_members)

          # Create membership attributes
          Enum.map(member_ids, fn actor_id ->
            %{
              group_id: group_id,
              actor_id: actor_id,
              account_id: admin_subject.account.id
            }
          end)
        end)
      end)

    # Bulk insert memberships
    memberships
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Membership, chunk)
    end)

    now = DateTime.utc_now()

    group_values = [
      %{
        id: Ecto.UUID.generate(),
        name: "Engineering",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Finance",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        name: "Synced Group with long name",
        type: :static,
        account_id: account.id,
        inserted_at: now,
        updated_at: now
      }
    ]

    {3, group_results} =
      Repo.insert_all(Group, group_values, returning: [:id, :name])

    for group <- group_results do
      IO.puts("  Name: #{group.name}  ID: #{group.id}")
    end

    # Reload as structs for further use
    [eng_group_id, finance_group_id, synced_group_id] = Enum.map(group_results, & &1.id)

    eng_group = Repo.get_by!(Group, id: eng_group_id)
    finance_group = Repo.get_by!(Group, id: finance_group_id)
    synced_group = Repo.get_by!(Group, id: synced_group_id)

    # Add admin as member of engineering group directly
    %Membership{
      group_id: eng_group.id,
      actor_id: admin_subject.actor.id,
      account_id: admin_subject.account.id
    }
    |> Repo.insert!()

    # Add unprivileged user as member of finance group directly
    %Membership{
      group_id: finance_group.id,
      actor_id: unprivileged_subject.actor.id,
      account_id: unprivileged_subject.account.id
    }
    |> Repo.insert!()

    # Add admin and unprivileged user as members of synced group
    %Membership{
      group_id: synced_group.id,
      actor_id: admin_subject.actor.id,
      account_id: admin_subject.account.id
    }
    |> Repo.insert!()

    %Membership{
      group_id: synced_group.id,
      actor_id: unprivileged_subject.actor.id,
      account_id: unprivileged_subject.account.id
    }
    |> Repo.insert!()

    # Add service account (Backup Manager) to synced group
    %Membership{
      group_id: synced_group.id,
      actor_id: service_account_actor.id,
      account_id: service_account_actor.account_id
    }
    |> Repo.insert!()

    synced_group = synced_group

    extra_group_names = [
      "gcp-logging-viewers",
      "gcp-security-admins",
      "gcp-organization-admins",
      "Admins",
      "Product",
      "Product Engineering",
      "gcp-developers"
    ]

    extra_group_values =
      Enum.map(extra_group_names, fn name ->
        %{
          id: Ecto.UUID.generate(),
          name: name,
          type: :static,
          account_id: account.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, extra_group_results} =
      Repo.insert_all(Group, extra_group_values, returning: [:id])

    # Add admin as member of each extra group
    for %{id: group_id} <- extra_group_results do
      %Membership{
        group_id: group_id,
        actor_id: admin_subject.actor.id,
        account_id: admin_subject.account.id
      }
      |> Repo.insert!()
    end

    IO.puts("")

    # Create relay token manually
    secret_fragment = Crypto.random_token(32, encoder: :hex32)
    secret_salt = Crypto.random_token(16)
    secret_hash = Crypto.hash(:sha3_256, secret_fragment <> secret_salt)

    global_relay_token =
      %Domain.RelayToken{
        secret_fragment: secret_fragment,
        secret_salt: secret_salt,
        secret_hash: secret_hash
      }
      |> Ecto.Changeset.change()
      |> Repo.insert!()

    global_relay_token =
      global_relay_token
      |> maybe_repo_update.(
        id: Ecto.UUID.cast!("e82fcdc1-057a-4015-b90b-3b18f0f28053"),
        secret_salt: "lZWUdgh-syLGVDsZEu_29A",
        secret_fragment: "C14NGA87EJRR03G4QPR07A9C6G784TSSTHSF4TI5T0GD8D6L0VRG====",
        secret_hash: "c3c9a031ae98f111ada642fddae546de4e16ceb85214ab4f1c9d0de1fc472797"
      )

    global_relay_encoded_token =
      Auth.encode_fragment!(global_relay_token)

    IO.puts("Created global relay token:")
    IO.puts("  Token: #{global_relay_encoded_token}")
    IO.puts("")

    # Create relays directly using the inline upsert logic from API.Relay.Socket
    relay_context = %Auth.Context{
      type: :relay,
      user_agent: "Ubuntu/14.04 connlib/0.7.412",
      remote_ip: {100, 64, 100, 58}
    }

    # Create first global relay
    global_relay =
      %Relay{}
      |> Ecto.Changeset.cast(
        %{
          name: "global-relay-1",
          ipv4: {189, 172, 72, 111},
          ipv6: {0, 0, 0, 0, 0, 0, 0, 1}
        },
        [:name, :ipv4, :ipv6]
      )
      |> put_change(:last_seen_at, DateTime.utc_now())
      |> put_change(:last_seen_user_agent, relay_context.user_agent)
      |> put_change(:last_seen_remote_ip, relay_context.remote_ip)
      |> put_change(:last_seen_version, "0.7.412")
      |> Repo.insert!()

    # Create additional global relays
    for i <- 1..5 do
      _global_relay =
        %Relay{}
        |> Ecto.Changeset.cast(
          %{
            name: "global-relay-#{i + 1}",
            ipv4: {189, 172, 72, 111 + i},
            ipv6: {0, 0, 0, 0, 0, 0, 0, i}
          },
          [:name, :ipv4, :ipv6]
        )
        |> put_change(:last_seen_at, DateTime.utc_now())
        |> put_change(:last_seen_user_agent, relay_context.user_agent)
        |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: {189, 172, 72, 111 + i}})
        |> put_change(:last_seen_version, "0.7.412")
        |> Repo.insert!()
    end

    IO.puts("Created global relays:")
    IO.puts("  Relay: IPv4: #{global_relay.ipv4} IPv6: #{global_relay.ipv6}")
    IO.puts("")

    site =
      %Site{account: account}
      |> Ecto.Changeset.cast(%{name: "mycro-aws-gws"}, [:name])
      |> Domain.Changeset.trim_change([:name])
      |> Domain.Changeset.put_default_value(:name, &NameGenerator.generate/0)
      |> Ecto.Changeset.validate_required([:name])
      |> Site.changeset()
      |> Domain.Changeset.put_default_value(:managed_by, :account)
      |> Ecto.Changeset.put_change(:account_id, account.id)
      |> Repo.insert!()

    # Create gateway token manually
    secret_fragment = Crypto.random_token(32, encoder: :hex32)
    secret_salt = Crypto.random_token(16)
    secret_hash = Crypto.hash(:sha3_256, secret_fragment <> secret_salt)

    gateway_token =
      %Domain.GatewayToken{
        account_id: site.account_id,
        site_id: site.id,
        secret_fragment: secret_fragment,
        secret_salt: secret_salt,
        secret_hash: secret_hash
      }
      |> Ecto.Changeset.change()
      |> Repo.insert!()

    gateway_token =
      gateway_token
      |> maybe_repo_update.(
        id: Ecto.UUID.cast!("2274560b-e97b-45e4-8b34-679c7617e98d"),
        secret_salt: "uQyisyqrvYIIitMXnSJFKQ",
        secret_fragment: "O02L7US2J3VINOMPR9J6IL88QIQP6UO8AQVO6U5IPL0VJC22JGH0====",
        secret_hash: "876f20e8d4de25d5ffac40733f280782a7d8097347d77415ab6e4e548f13d2ee"
      )

    gateway_encoded_token = Auth.encode_fragment!(gateway_token)

    IO.puts("Created sites:")
    IO.puts("  #{site.name} token: #{gateway_encoded_token}")
    IO.puts("")

    # Create gateway directly
    {:ok, gateway1} =
      create_gateway(
        %{
          site_id: site.id,
          external_id: Ecto.UUID.generate(),
          name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
        },
        %Auth.Context{
          type: :gateway,
          user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
          remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
        }
      )

    # Create another gateway
    {:ok, gateway2} =
      create_gateway(
        %{
          site_id: site.id,
          external_id: Ecto.UUID.generate(),
          name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
          public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
        },
        %Auth.Context{
          type: :gateway,
          user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
          remote_ip: %Postgrex.INET{address: {164, 112, 78, 62}}
        }
      )

    for i <- 1..10 do
      # Create more gateways
      {:ok, _gateway} =
        create_gateway(
          %{
            site_id: site.id,
            external_id: Ecto.UUID.generate(),
            name: "gw-#{Crypto.random_token(5, encoder: :user_friendly)}",
            public_key: :crypto.strong_rand_bytes(32) |> Base.encode64()
          },
          %Auth.Context{
            type: :gateway,
            user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
            remote_ip: %Postgrex.INET{address: {164, 112, 78, 62 + i}}
          }
        )
    end

    IO.puts("Created gateways:")
    gateway_name = "#{site.name}-#{gateway1.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    External UUID: #{gateway1.external_id}")
    IO.puts("    Public Key: #{gateway1.public_key}")
    IO.puts("    IPv4: #{gateway1.ipv4_address.address} IPv6: #{gateway1.ipv6_address.address}")
    IO.puts("")

    gateway_name = "#{site.name}-#{gateway2.name}"
    IO.puts("  #{gateway_name}:")
    IO.puts("    External UUID: #{gateway1.external_id}")
    IO.puts("    Public Key: #{gateway2.public_key}")
    IO.puts("    IPv4: #{gateway2.ipv4_address.address} IPv6: #{gateway2.ipv6_address.address}")
    IO.puts("")

    {:ok, dns_google_resource} =
      create_resource(
        %{
          type: :dns,
          name: "foobar.com",
          address: "foobar.com",
          address_description: "https://foobar.com/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, firez_one} =
      create_resource(
        %{
          type: :dns,
          name: "**.firez.one",
          address: "**.firez.one",
          address_description: "https://firez.one/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, firezone_dev} =
      create_resource(
        %{
          type: :dns,
          name: "*.firezone.dev",
          address: "*.firezone.dev",
          address_description: "https://firezone.dev/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, example_dns} =
      create_resource(
        %{
          type: :dns,
          name: "example.com",
          address: "example.com",
          address_description: "https://example.com:1234/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, ip6only} =
      create_resource(
        %{
          type: :dns,
          name: "ip6only",
          address: "ip6only.me",
          address_description: "https://ip6only.me/",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, address_description_null_resource} =
      create_resource(
        %{
          type: :dns,
          name: "Example",
          address: "*.example.com",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, dns_gitlab_resource} =
      create_resource(
        %{
          type: :dns,
          name: "gitlab.mycorp.com",
          address: "gitlab.mycorp.com",
          address_description: "https://gitlab.mycorp.com/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, ip_resource} =
      create_resource(
        %{
          type: :ip,
          name: "Public DNS",
          address: "1.2.3.4",
          address_description: "http://1.2.3.4:3000/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, cidr_resource} =
      create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network",
          address: "172.20.0.0/16",
          address_description: "172.20.0.0/16",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, ipv6_resource} =
      create_resource(
        %{
          type: :cidr,
          name: "MyCorp Network (IPv6)",
          address: "172:20::/64",
          address_description: "172:20::/64",
          site_id: site.id,
          filters: []
        },
        admin_subject
      )

    {:ok, dns_httpbin_resource} =
      create_resource(
        %{
          type: :dns,
          name: "**.httpbin",
          address: "**.httpbin",
          address_description: "http://httpbin/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    {:ok, search_domain_resource} =
      create_resource(
        %{
          type: :dns,
          name: "**.httpbin.search.test",
          address: "**.httpbin.search.test",
          address_description: "http://httpbin/",
          site_id: site.id,
          filters: [
            %{ports: ["80", "433"], protocol: :tcp},
            %{ports: ["53"], protocol: :udp},
            %{protocol: :icmp}
          ]
        },
        admin_subject
      )

    IO.puts("Created resources:")
    IO.puts("  #{dns_google_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{address_description_null_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{dns_gitlab_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firez_one.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{firezone_dev.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{example_dns.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{ip_resource.address} - IP - gateways: #{gateway_name}")
    IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{ipv6_resource.address} - CIDR - gateways: #{gateway_name}")
    IO.puts("  #{dns_httpbin_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("  #{search_domain_resource.address} - DNS - gateways: #{gateway_name}")
    IO.puts("")

    # Helper function to create policy directly without context module
    create_policy = fn attrs, subject ->
      policy =
        %Policy{
          account_id: subject.account.id,
          description: attrs[:description] || attrs["description"],
          group_id: attrs[:group_id] || attrs["group_id"],
          resource_id: attrs[:resource_id] || attrs["resource_id"],
          conditions: attrs[:conditions] || attrs["conditions"] || []
        }
        |> Repo.insert!()

      {:ok, policy}
    end

    {:ok, policy} =
      create_policy.(
        %{
          description: "All Access To Google",
          group_id: everyone_group.id,
          resource_id: dns_google_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firez.one",
          group_id: synced_group.id,
          resource_id: firez_one.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firez.one",
          group_id: everyone_group.id,
          resource_id: example_dns.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To firezone.dev",
          group_id: everyone_group.id,
          resource_id: firezone_dev.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To ip6only.me",
          group_id: synced_group.id,
          resource_id: ip6only.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All access to Google",
          group_id: everyone_group.id,
          resource_id: address_description_null_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Eng Access To Gitlab",
          group_id: eng_group.id,
          resource_id: dns_gitlab_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To Network",
          group_id: synced_group.id,
          resource_id: cidr_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To Network",
          group_id: synced_group.id,
          resource_id: ipv6_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To **.httpbin",
          group_id: everyone_group.id,
          resource_id: dns_httpbin_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Synced Group Access To **.httpbin",
          group_id: synced_group.id,
          resource_id: dns_httpbin_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "All Access To **.httpbin.search.test",
          group_id: everyone_group.id,
          resource_id: search_domain_resource.id
        },
        admin_subject
      )

    {:ok, _} =
      create_policy.(
        %{
          description: "Synced Group Access To **.httpbin.search.test",
          group_id: synced_group.id,
          resource_id: search_domain_resource.id
        },
        admin_subject
      )

    IO.puts("Policies Created")
    IO.puts("")

    membership =
      Repo.get_by(Membership,
        group_id: synced_group.id,
        actor_id: unprivileged_actor.id
      )

    # Create policy_authorization directly without context module
    _policy_authorization =
      %PolicyAuthorization{
        client_id: user_iphone.id,
        gateway_id: gateway1.id,
        resource_id: cidr_resource.id,
        policy_id: policy.id,
        membership_id: membership.id,
        account_id: unprivileged_subject.account.id,
        token_id: unprivileged_subject.credential.id,
        client_remote_ip: {127, 0, 0, 1},
        client_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
        gateway_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}, netmask: nil},
        expires_at: unprivileged_subject.expires_at || DateTime.utc_now() |> DateTime.add(3600)
      }
      |> Repo.insert!()
  end
end

Domain.Repo.Seeds.seed()
