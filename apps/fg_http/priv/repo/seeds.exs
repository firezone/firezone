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

alias FgHttp.{Devices, Rules, Users}

{:ok, user} =
  Users.create_user(%{
    email: "factory@factory",
    password: "factory",
    password_confirmation: "factory"
  })

{:ok, device} =
  Devices.create_device(%{
    user_id: user.id,
    name: "Factory Device",
    public_key: "3Fo+SNnDJ6hi8qzPt3nWLwgjCVwvpjHL35qJeatKwEc=",
    server_public_key: "QFvMfHTjlJN9cfUiK1w4XmxOomH6KRTCMrVC6z3TWFM=",
    private_key: "2JSZtpSHM+69Hm7L3BSGIymbq0byw39iWLevKESd1EM=",
    preshared_key: "hQS+GkbTWfEhueLM8RJ2anjC4RxzdgL4dpTIetHf6GU=",
    last_ip: %Postgrex.INET{address: {127, 0, 0, 1}}
  })

{:ok, _rule} =
  Rules.create_rule(%{
    device_id: device.id,
    destination: %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 0}
  })
