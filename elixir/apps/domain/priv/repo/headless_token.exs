{:ok, remote_ip} = System.get_env("REMOTE_IP") |> String.to_charlist() |> :inet.parse_address()
user_agent = System.get_env("USER_AGENT")
provider = Domain.Repo.get_by(Domain.Auth.Provider, adapter: :userpass)

{:ok, subject} =
  Domain.Auth.sign_in(
    provider,
    "firezone-unprivileged-1@localhost",
    "Firezone1234",
    user_agent,
    remote_ip
  )

{:ok, token} = Domain.Auth.create_session_token_from_subject(subject)
IO.puts(token)
