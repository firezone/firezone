Domain.Repo.get_by(Domain.Accounts.Account, name: "Firezone Account")
|> Domain.Relays.Group.Changeset.create_changeset(%{name_prefix: "docker_group", tokens: [%{}]})
|> Domain.Repo.insert!()
|> Map.get(:tokens)
|> hd()
|> Domain.Relays.encode_token!()
|> IO.puts()
