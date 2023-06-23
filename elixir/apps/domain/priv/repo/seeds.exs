alias Domain.{Repo, Accounts, Auth, Actors, Relays, Gateways, Resources}

# This function is used to update fields if STATIC_SEEDS is set,
# which helps with static docker-compose environment for local development.
maybe_repo_update = fn resource, values ->
  if System.get_env("STATIC_SEEDS") == "true" do
    Ecto.Changeset.change(resource, values)
    |> Repo.update!()
  else
    resource
  end
end

{:ok, account} = Accounts.create_account(%{name: "Firezone Account"})
account = maybe_repo_update.(account, id: "c89bcc8c-9392-4dae-a40d-888aef6d28e0")

{:ok, other_account} = Accounts.create_account(%{name: "Other Corp Account"})
other_account = maybe_repo_update.(other_account, id: "9b9290bf-e1bc-4dd3-b401-511908262690")

IO.puts("Created accounts: ")

for item <- [account, other_account] do
  IO.puts("  #{item.id}: #{item.name}")
end

IO.puts("")

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
    type: :account_user,
    name: "Firezone Unprivileged"
  })

{:ok, admin_actor} =
  Actors.create_actor(email_provider, admin_actor_email, %{
    type: :account_admin_user,
    name: "Firezone Admin"
  })

{:ok, unprivileged_actor_userpass_identity} =
  Auth.create_identity(unprivileged_actor, userpass_provider, unprivileged_actor_email, %{
    "password" => "Firezone1234",
    "password_confirmation" => "Firezone1234"
  })

{:ok, _admin_actor_userpass_identity} =
  Auth.create_identity(admin_actor, userpass_provider, admin_actor_email, %{
    "password" => "Firezone1234",
    "password_confirmation" => "Firezone1234"
  })

unprivileged_actor_userpass_identity =
  maybe_repo_update.(unprivileged_actor_userpass_identity,
    id: "7da7d1cd-111c-44a7-b5ac-4027b9d230e5"
  )

unprivileged_actor_token = hd(unprivileged_actor.identities).provider_virtual_state.sign_in_token
admin_actor_token = hd(admin_actor.identities).provider_virtual_state.sign_in_token

unprivileged_subject =
  Auth.build_subject(
    unprivileged_actor_userpass_identity,
    DateTime.utc_now() |> DateTime.add(365, :day),
    "iOS/12.5 (iPhone) connlib/0.7.412",
    {172, 28, 0, 1}
  )

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
  IO.puts("  #{login}, #{type}, password: #{password}, email token: #{email_token} (exp in 15m)")
end

IO.puts("")

relay_group =
  account
  |> Relays.Group.Changeset.create_changeset(%{name: "mycorp-aws-relays", tokens: [%{}]})
  |> Repo.insert!()

relay_group_token = hd(relay_group.tokens)

relay_group_token =
  maybe_repo_update.(relay_group_token,
    id: "7286b53d-073e-4c41-9ff1-cc8451dad299",
    hash:
      "$argon2id$v=19$m=131072,t=8,p=4$aSw/NA3z0vGJjvF3ukOcyg$5MPWPXLETM3iZ19LTihItdVGb7ou/i4/zhpozMrpCFg",
    value: "EX77Ga0HKJUVLgcpMrN6HatdGnfvADYQrRjUWWyTqqt7BaUdEU3o9-FbBlRdINIK"
  )

IO.puts("Created relay groups:")
IO.puts("  #{relay_group.name} token: #{Relays.encode_token!(relay_group_token)}")
IO.puts("")

{:ok, relay} =
  Relays.upsert_relay(relay_group_token, %{
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

gateway_group_token = hd(gateway_group.tokens)

gateway_group_token =
  maybe_repo_update.(
    gateway_group_token,
    id: "3cef0566-adfd-48fe-a0f1-580679608f6f",
    hash:
      "$argon2id$v=19$m=131072,t=8,p=4$w0aXBd0iv/OTizWGBRTKiw$m6J0YXRsFCO95Q8LeVvH+CxFTy0Li7Lrcs3NDJRykCA",
    value: "jjtzxRFJPZGBc-oCZ9Dy2FwjwaHXMAUdpzuRr2sRropx75-znh_xp_5bT5Ono-rb"
  )

IO.puts("Created gateway groups:")
IO.puts("  #{gateway_group.name_prefix} token: #{Gateways.encode_token!(gateway_group_token)}")
IO.puts("")

{:ok, gateway} =
  Gateways.upsert_gateway(gateway_group_token, %{
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
      type: :dns,
      address: "gitlab.mycorp.com",
      connections: [%{gateway_group_id: gateway_group.id}]
    },
    admin_subject
  )

{:ok, cidr_resource} =
  Resources.create_resource(
    %{
      type: :cidr,
      address: "172.172.0.1/16",
      connections: [%{gateway_group_id: gateway_group.id}]
    },
    admin_subject
  )

IO.puts("Created resources:")
IO.puts("  #{dns_resource.address} - DNS - #{dns_resource.ipv4} - gateways: #{gateway_name}")
IO.puts("  #{cidr_resource.address} - CIDR - gateways: #{gateway_name}")
IO.puts("")

{:ok, unprivileged_subject_session_token} =
  Auth.create_session_token_from_subject(unprivileged_subject)

IO.puts("Created device tokens:")
IO.puts("  #{unprivileged_actor_email} token: #{unprivileged_subject_session_token}")
IO.puts("")
