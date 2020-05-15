# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FgHttp.Repo.insert!(%FgHttp.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias FgHttp.Repo

Repo.transaction(fn ->
  {:ok, user} = FgHttp.Users.create_user(%{email: "testuser@fireguard.network"})

  {:ok, device} =
    FgHttp.Devices.create_device(%{
      name: "Seed",
      public_key: "Seed",
      last_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
      user_id: user.id
    })

  {:ok, rule} =
    FgHttp.Rules.create_rule(%{
      destination: %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 0},
      device_id: device.id
    })
end)
