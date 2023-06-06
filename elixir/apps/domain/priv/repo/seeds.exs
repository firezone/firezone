alias Domain.{Repo, Accounts, Auth, Actors, Relays, Gateways, Resources}

{:ok, account} = Accounts.create_account(%{name: "Firezone Account"})
{:ok, _account} = Accounts.create_account(%{name: "Other Corp Account"})

{:ok, email_provider} =
  Auth.create_provider(account, %{
    name: "email",
    adapter: :email,
    adapter_config: %{}
  })

{:ok, _oidc_provider} =
  Auth.create_provider(account, %{
    name: "Vault",
    adapter: :openid_connect,
    adapter_config: %{
      "client_id" => "CLIENT_ID",
      "client_secret" => "CLIENT_SECRET",
      "response_type" => "code",
      "scope" => "openid email offline_access",
      "discovery_document_uri" => "https://common.auth0.com/.well-known/openid-configuration"
    }
  })

{:ok, userpass_provider} =
  Auth.create_provider(account, %{
    name: "UserPass",
    adapter: :userpass,
    adapter_config: %{}
  })

unprivileged_actor_email = "firezone-unprivileged-1@localhost"
admin_actor_email = "firezone@localhost"

{:ok, unprivileged_actor} =
  Actors.create_actor(email_provider, unprivileged_actor_email, %{
    type: :account_user
  })

{:ok, admin_actor} =
  Actors.create_actor(email_provider, admin_actor_email, %{
    type: :account_admin_user
  })

{:ok, _unprivileged_actor_userpass_identity} =
  Auth.create_identity(unprivileged_actor, userpass_provider, unprivileged_actor_email, %{
    "password" => "Firezone1234",
    "password_confirmation" => "Firezone1234"
  })

{:ok, _admin_actor_userpass_identity} =
  Auth.create_identity(admin_actor, userpass_provider, admin_actor_email, %{
    "password" => "Firezone1234",
    "password_confirmation" => "Firezone1234"
  })

unprivileged_actor_token = hd(unprivileged_actor.identities).provider_virtual_state.sign_in_token
admin_actor_token = hd(admin_actor.identities).provider_virtual_state.sign_in_token

admin_subject =
  Auth.build_subject(
    hd(admin_actor.identities),
    nil,
    "iOS/12.5 (iPhone) connlib/0.7.412",
    {100, 64, 100, 58}
  )

IO.puts("Created users: ")

for {type, login, password, email_token} <- [
      {unprivileged_actor.type, unprivileged_actor_email, "Firezone1234",
       unprivileged_actor_token},
      {admin_actor.type, admin_actor_email, "Firezone1234", admin_actor_token}
    ] do
  IO.puts("  #{login}, #{type}, password: #{password}, email token: #{email_token}")
end

IO.puts("")

relay_group =
  account
  |> Relays.Group.Changeset.create_changeset(%{name: "mycorp-aws-relays", tokens: [%{}]})
  |> Repo.insert!()

IO.puts("Created relay groups:")
IO.puts("  #{relay_group.name} token: #{Relays.encode_token!(hd(relay_group.tokens))}")
IO.puts("")

{:ok, relay} =
  Relays.upsert_relay(hd(relay_group.tokens), %{
    ipv4: {189, 172, 73, 111},
    ipv6: {0, 0, 0, 0, 0, 0, 0, 1},
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 111}}
  })

IO.puts("Created relays:")
IO.puts("  Group #{relay_group.name}:")
IO.puts("    IPv4: #{relay.ipv4} IPv6: #{relay.ipv6}")
IO.puts("")

gateway_group =
  account
  |> Gateways.Group.Changeset.create_changeset(%{name_prefix: "mycro-aws-gws", tokens: [%{}]})
  |> Repo.insert!()

IO.puts("Created gateway groups:")

IO.puts(
  "  #{gateway_group.name_prefix} token: #{Gateways.encode_token!(hd(gateway_group.tokens))}"
)

IO.puts("")

{:ok, gateway} =
  Gateways.upsert_gateway(hd(gateway_group.tokens), %{
    external_id: Ecto.UUID.generate(),
    name_suffix: "gw-#{Domain.Crypto.rand_string(5)}",
    public_key: :crypto.strong_rand_bytes(32) |> Base.encode64(),
    last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
    last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
  })

IO.puts("Created gateways:")
gateway_name = "#{gateway_group.name_prefix}-#{gateway.name_suffix}"
IO.puts("  #{gateway_name}:")
IO.puts("    External UUID: #{gateway.external_id}")
IO.puts("    Public Key: #{gateway.public_key}")
IO.puts("    IPv4: #{gateway.ipv4} IPv6: #{gateway.ipv6}")
IO.puts("")

{:ok, dns_resource} =
  Resources.create_resource(
    %{
      address: "gitlab.mycorp.com",
      connections: [%{gateway_id: gateway.id}]
    },
    admin_subject
  )

{:ok, cidr_resource} =
  Resources.create_resource(
    %{
      address: "172.172.0.1/16",
      connections: [%{gateway_id: gateway.id}]
    },
    admin_subject
  )

IO.puts("Created resources:")

IO.puts("  #{dns_resource.address} - DNS - #{dns_resource.ipv4} - gateways: #{gateway_name}")
IO.puts("  #{cidr_resource.address} - CIDR - #{cidr_resource.ipv4} - gateways: #{gateway_name}")
IO.puts("")
