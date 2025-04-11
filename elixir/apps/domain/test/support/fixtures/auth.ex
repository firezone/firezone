defmodule Domain.Fixtures.Auth do
  use Domain.Fixture
  alias Domain.Auth

  # this key is revoked so don't bother trying to use it
  @google_workspace_private_key """
  -----BEGIN PRIVATE KEY-----
  MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCZU+IlZMT1ExqS
  LAi7Fa2bGYiGSFIvbVoOVvu8VZyOAR3Bjfe2TiLzVTc35+D5fYzQftx7sC0ZF6Ub
  ZSK5mgBi0LcVw8xsMcDhroD0MZdE5E1Lg/tvCdYJCkWFsvCHk8yN40hPgw2lB9Bu
  xJ4uV5agl8zAkEr+Y8ck0BFY3aK5uyA5McdmakkEUCYRfUaoRCP4y+kR22PJJnYN
  yYma4nLk6b3OwMs58z5U0N2tmDj8o8zWPSlh4HJgMmOnwtl1EjZ9ZlwjENhzooL2
  E00gFglm8Lgj34HZp6zhF3bhiCQz0j06puLScXAsLDa5AMf4mBVNsefG59lGZLd4
  HEaRoxrjAgMBAAECggEAHdiDO84qvJ3UXUGvDWPB4GAPADyRquO5VPM/m0B68fVr
  qmKNJnJ9QSqETiCX3VjAEVGwb28yyCCfJf8AzGoayyFfkiAD6cehiQyj02TX0jQy
  i5GMXufmPuo98DGNuoZdmfz09W1IOaiUvQsO02x/SJFj7NPplS0s9ZB+3/J8m3Rx
  OmYzWg27zV5yITSE4N5FVfK7zfOHzFSdo+yXULRS8ZfzdQeQBFqlnWYSMe9P3QlG
  kJDyB0JULGcUfpcKQfcI//AMSFjhNn5CngYCU4Qedsm04PmbQr73qMZdbmzLw1Nq
  NToSwc9SsH2rUBjwffdUK8JNE2wY8JVF96pqX3C8QQKBgQDNQ2o5HZmI2vGqVG0G
  8/cDVDoJuEjgVPuYAeCHjfjXKR/AKanUTu0Pv/Q45K419T4IdMbOcqr4TvkDHsgZ
  qQ7Uus+soDz6kY5oyYL43NBS1XAeTmjBkyKT4+k3goUg1+rPyKEATT3dXwT377CS
  CC3HQE4mZ4RFhEocxku0l/M1oQKBgQC/Ohm3f2/tod5xeJSXfdC0mHKcxcTjQiax
  pYWHbr+YH4GRBTZUNpCMIoYpSjLCoCXcQ5yhxK3K2BEp/5t44OrmfI1o91Xz2XXJ
  x0A7q27umTRug8J7E3GaoTDutFBUP5C0nJSQgdQaTOAMzZpJqtM27tFJYAHxI2gS
  0cEeFsM6AwKBgH/r0qhTvRqgMFnRkbzyj++gLyddlPVRoRZjnRV9siYNN/9fN7rb
  kTvuifpm8fcopodIl5mTtt9XADMknNn5FQgYgFJ57mbODa1aYGhN3Pqyj9QjU3/H
  /ZWjRPXWPrdwOKNTyprQiIyMqiEGXMk1laoGdm3St4lHX5S9M/MRe33hAoGBAJXi
  TFXvpSN1RI1cHdu/2d4zv2HyAai/KOUE/+xvee0ahMvOcg7/1byBMvcaGT9Dl2lV
  9Wc2aaIcSRfKKWpNoNCXv58Ofmhrgk9txYL/lCugGeCllcIyM1EoFtqCqpPeXuWx
  9SBvInia2OIwJUaohnUAKzp/7gW74s8daWjUHqFRAoGAJ6JJYh749pfDYB4LKwia
  R9Iyld0qDPR6FXY0ZkOWKczHM2OFjhTT5LglNhoso4zavakyIRmWH8y1tiQnSO/m
  XI2ckSJQwxpnezLFkP2poJaaM4UqbvRFpXAvUOwvMLpbN57WSngm7Gsm6c9dKvZl
  7aghWWogzrdN9hMNjXRevao=
  -----END PRIVATE KEY-----
  """

  def user_password, do: "Hello w0rld!"
  def remote_ip, do: {100, 64, 100, 58}
  def user_agent, do: "iOS/12.5 (iPhone) connlib/1.3.0"
  def email(domain \\ "example.com"), do: "user-#{unique_integer()}@#{domain}"

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :email, name: name}) do
    "user-#{unique_integer()}@#{String.downcase(name)}.com"
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: :userpass, name: name}) do
    "user-#{unique_integer()}@#{String.downcase(name)}.com"
  end

  def random_provider_identifier(%Domain.Auth.Provider{adapter: _other_adapter}) do
    Ecto.UUID.generate()
  end

  def random_workos_org_identifier do
    chars = Range.to_list(?A..?Z) ++ Range.to_list(?0..?9)
    str = for _ <- 1..26, into: "", do: <<Enum.random(chars)>>
    "org_#{str}"
  end

  def provider_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "provider-#{unique_integer()}",
      adapter: :email,
      adapter_config: %{},
      created_by: :system,
      provisioner: :manual
    })
  end

  def openid_connect_adapter_config(overrides \\ %{}) do
    for {k, v} <- overrides,
        into: %{
          "discovery_document_uri" =>
            "https://firezone.example.com/.well-known/openid-configuration",
          "client_id" => "client-id-#{unique_integer()}",
          "client_secret" => "client-secret-#{unique_integer()}",
          "response_type" => "code",
          "scope" => "openid email profile"
        } do
      {to_string(k), v}
    end
  end

  def create_email_provider(attrs \\ %{}) do
    attrs = provider_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def start_and_create_openid_connect_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri: "http://localhost:#{bypass.port}/.well-known/openid-configuration"
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_openid_connect_provider()

    {provider, bypass}
  end

  def start_and_create_google_workspace_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri:
          "http://localhost:#{bypass.port}/.well-known/openid-configuration",
        scope: Domain.Auth.Adapters.GoogleWorkspace.Settings.scope() |> Enum.join(" "),
        service_account_json_key: %{
          type: "service_account",
          project_id: "firezone-test",
          private_key_id: "e1fc5c12b490aaa1602f3de9133551952b749db3",
          private_key: @google_workspace_private_key,
          client_email: "firezone-idp-sync@firezone-test-391719.iam.gserviceaccount.com",
          client_id: "110986447653011314480",
          auth_uri: "https://accounts.google.com/o/oauth2/auth",
          token_uri: "https://oauth2.googleapis.com/token",
          auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs",
          client_x509_cert_url:
            "https://www.googleapis.com/robot/v1/metadata/x509/firezone-idp-sync%40firezone-test-111111.iam.gserviceaccount.com",
          universe_domain: "googleapis.com"
        }
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_google_workspace_provider()

    {provider, bypass}
  end

  def start_and_create_microsoft_entra_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri:
          "http://localhost:#{bypass.port}/.well-known/openid-configuration",
        scope: Domain.Auth.Adapters.MicrosoftEntra.Settings.scope() |> Enum.join(" ")
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_microsoft_entra_provider()

    {provider, bypass}
  end

  def start_and_create_okta_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()
    api_base_url = "http://localhost:#{bypass.port}"

    adapter_config =
      openid_connect_adapter_config(
        api_base_url: api_base_url,
        okta_account_domain: api_base_url,
        discovery_document_uri: "#{api_base_url}/.well-known/openid-configuration",
        scope: Domain.Auth.Adapters.Okta.Settings.scope() |> Enum.join(" ")
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_okta_provider()

    {provider, bypass}
  end

  def start_and_create_jumpcloud_provider(attrs \\ %{}) do
    bypass = Domain.Mocks.OpenIDConnect.discovery_document_server()

    adapter_config =
      openid_connect_adapter_config(
        discovery_document_uri:
          "http://localhost:#{bypass.port}/.well-known/openid-configuration",
        scope: Domain.Auth.Adapters.JumpCloud.Settings.scope() |> Enum.join(" "),
        workos_org: %{
          "id" => Fixtures.WorkOS.random_workos_id(:org),
          "name" => Ecto.UUID.generate(),
          "object" => "organization",
          "domains" => [],
          "created_at" => DateTime.utc_now() |> DateTime.add(-1, :day),
          "updated_at" => DateTime.utc_now() |> DateTime.add(-1, :day),
          "allow_profiles_outside_organization" => false
        }
      )

    provider =
      attrs
      |> Enum.into(%{adapter_config: adapter_config})
      |> create_jumpcloud_provider()

    {provider, bypass}
  end

  def create_openid_connect_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :openid_connect,
        provisioner: :manual
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    provider =
      provider
      |> Ecto.Changeset.change(
        disabled_at: nil,
        adapter_state: %{}
      )
      |> Repo.update!()

    provider
  end

  def create_google_workspace_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :google_workspace,
        provisioner: :custom
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    update!(provider,
      disabled_at: nil,
      adapter_state: %{
        "userinfo" => %{"sub" => email()},
        "access_token" => "OIDC_ACCESS_TOKEN",
        "refresh_token" => "OIDC_REFRESH_TOKEN",
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day),
        "claims" => "openid email profile offline_access"
      }
    )
  end

  def create_microsoft_entra_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :microsoft_entra,
        provisioner: :custom
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    update!(provider,
      disabled_at: nil,
      adapter_state: %{
        "access_token" => "OIDC_ACCESS_TOKEN",
        "refresh_token" => "OIDC_REFRESH_TOKEN",
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day),
        "claims" => "openid email profile offline_access"
      }
    )
  end

  def create_okta_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :okta,
        provisioner: :custom
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {access_token, attrs} =
      pop_assoc_fixture(attrs, :access_token, & &1)

    {:ok, provider} = Auth.create_provider(account, attrs)

    access_token = access_token || "OIDC_ACCESS_TOKEN"

    update!(provider,
      disabled_at: nil,
      adapter_state: %{
        "access_token" => access_token,
        "refresh_token" => "OIDC_REFRESH_TOKEN",
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day),
        "claims" => "openid email profile offline_access"
      }
    )
  end

  def create_jumpcloud_provider(attrs \\ %{}) do
    attrs =
      %{
        adapter: :jumpcloud,
        provisioner: :custom
      }
      |> Map.merge(Enum.into(attrs, %{}))
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)

    update!(provider,
      disabled_at: nil,
      adapter_state: %{
        "access_token" => "OIDC_ACCESS_TOKEN",
        "refresh_token" => "OIDC_REFRESH_TOKEN",
        "expires_at" => DateTime.utc_now() |> DateTime.add(1, :day),
        "claims" => "openid email profile offline_access"
      }
    )
  end

  def create_userpass_provider(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{adapter: :userpass})
      |> provider_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Auth.create_provider(account, attrs)
    provider
  end

  def disable_provider(provider) do
    provider = Repo.preload(provider, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: provider.account,
        actor: [type: :account_admin_user]
      )

    {:ok, group} = Auth.disable_provider(provider, subject)
    group
  end

  def delete_provider(provider) do
    update!(provider, deleted_at: DateTime.utc_now())
  end

  def fail_provider_sync(provider) do
    update!(provider,
      last_sync_error: "Message from fixture",
      last_syncs_failed: 3,
      sync_disabled_at: DateTime.utc_now()
    )
  end

  def finish_provider_sync(provider) do
    update!(provider,
      last_synced_at: DateTime.utc_now(),
      last_sync_error: nil,
      last_syncs_failed: 0
    )
  end

  def identity_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      provider_virtual_state: %{}
    })
  end

  def create_identity(attrs \\ %{}) do
    attrs = identity_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        {provider, _bypass} =
          assoc_attrs
          |> Enum.into(%{account: account})
          |> start_and_create_openid_connect_provider()

        provider
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        })
        |> Fixtures.Actors.create_actor()
      end)

    {email, attrs} =
      Map.pop_lazy(attrs, :email, fn ->
        if Domain.Auth.valid_email?(provider_identifier) do
          provider_identifier
        else
          nil
        end
      end)

    attrs = Map.put(attrs, :provider_identifier, provider_identifier)
    attrs = Map.put(attrs, :provider_identifier_confirmation, provider_identifier)
    attrs = Map.put(attrs, :email, email)

    {:ok, identity} = Auth.upsert_identity(actor, provider, attrs)

    attrs = Map.take(attrs, [:provider_state, :created_by])

    identity
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  def delete_identity(identity) do
    update!(identity, deleted_at: DateTime.utc_now())
  end

  def build_context(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {type, attrs} = Map.pop(attrs, :type, :browser)

    {user_agent, attrs} =
      Map.pop_lazy(attrs, :user_agent, fn ->
        user_agent()
      end)

    {remote_ip, attrs} =
      Map.pop_lazy(attrs, :remote_ip, fn ->
        remote_ip()
      end)

    {remote_ip_location_region, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_region, fn ->
        Enum.random(["US", "UA"])
      end)

    {remote_ip_location_city, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_city, fn ->
        Enum.random(["Odessa", "New York"])
      end)

    {remote_ip_location_lat, attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_lat, fn ->
        Enum.random([37.7758, 40.7128])
      end)

    {remote_ip_location_lon, _attrs} =
      Map.pop_lazy(attrs, :remote_ip_location_lon, fn ->
        Enum.random([-122.4128, -74.0060])
      end)

    %Auth.Context{
      type: type,
      remote_ip: remote_ip,
      remote_ip_location_region: remote_ip_location_region,
      remote_ip_location_city: remote_ip_location_city,
      remote_ip_location_lat: remote_ip_location_lat,
      remote_ip_location_lon: remote_ip_location_lon,
      user_agent: user_agent
    }
  end

  def create_subject(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        relation = attrs[:provider] || attrs[:actor] || attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          Fixtures.Accounts.create_account(assoc_attrs)
        end
      end)

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Auth.Provider, relation.provider_id)
        else
          {provider, _bypass} =
            assoc_attrs
            |> Enum.into(%{account: account})
            |> start_and_create_openid_connect_provider()

          provider
        end
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Actors.Actor, relation.actor_id)
        else
          assoc_attrs
          |> Enum.into(%{
            type: :account_admin_user,
            account: account,
            provider: provider,
            provider_identifier: provider_identifier
          })
          |> Fixtures.Actors.create_actor()
        end
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        if actor.type in [:service_account, :api_client] do
          nil
        else
          assoc_attrs
          |> Enum.into(%{
            actor: actor,
            account: account,
            provider: provider,
            provider_identifier: provider_identifier
          })
          |> create_identity()
        end
      end)

    {expires_at, attrs} =
      Map.pop_lazy(attrs, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(60, :second)
      end)

    context_type =
      case actor.type do
        :service_account -> :client
        :api_client -> :api_client
        _ -> :browser
      end

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: context_type})
        |> build_context()
      end)

    {token, _attrs} =
      pop_assoc_fixture(attrs, :token, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          account: account,
          type: context.type,
          secret_nonce: Domain.Crypto.random_token(32, encoder: :hex32),
          actor: actor,
          identity: identity,
          expires_at: expires_at
        })
        |> Fixtures.Tokens.create_token()
      end)

    {:ok, subject} = Auth.build_subject(token, context)
    subject
  end

  def create_and_encode_token(attrs) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        relation = attrs[:provider] || attrs[:actor] || attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Accounts.Account, relation.account_id)
        else
          Fixtures.Accounts.create_account(assoc_attrs)
        end
      end)

    {provider, attrs} =
      pop_assoc_fixture(attrs, :provider, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Auth.Provider, relation.provider_id)
        else
          {provider, _bypass} =
            assoc_attrs
            |> Enum.into(%{account: account})
            |> start_and_create_openid_connect_provider()

          provider
        end
      end)

    {provider_identifier, attrs} =
      Map.pop_lazy(attrs, :provider_identifier, fn ->
        random_provider_identifier(provider)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Actors.Actor, relation.actor_id)
        else
          assoc_attrs
          |> Enum.into(%{
            type: :account_admin_user,
            account: account,
            provider: provider,
            provider_identifier: provider_identifier
          })
          |> Fixtures.Actors.create_actor()
        end
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{
          actor: actor,
          account: account,
          provider: provider,
          provider_identifier: provider_identifier
        })
        |> create_identity()
      end)

    {expires_at, attrs} =
      Map.pop_lazy(attrs, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(60, :second)
      end)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        build_context(assoc_attrs)
      end)

    {nonce, _attrs} =
      Map.pop_lazy(attrs, :nonce, fn ->
        Domain.Crypto.random_token(32, encoder: :hex32)
      end)

    {:ok, token} = Auth.create_token(identity, context, nonce, expires_at)
    {token, nonce <> Domain.Tokens.encode_fragment!(token)}
  end

  def remove_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.delete(subject.permissions, permission)}
  end

  def remove_permissions(%Auth.Subject{} = subject) do
    %{subject | permissions: MapSet.new()}
  end

  def set_permissions(%Auth.Subject{} = subject, permissions) do
    %{subject | permissions: MapSet.new(permissions)}
  end

  def add_permission(%Auth.Subject{} = subject, permission) do
    %{subject | permissions: MapSet.put(subject.permissions, permission)}
  end
end
