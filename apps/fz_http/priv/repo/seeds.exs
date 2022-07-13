# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FzHttp.Repo.insert!(%FzHttp.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias FzHttp.{Devices, ConnectivityChecks, Rules, Users}

{:ok, user} =
  Users.create_admin_user(%{
    email: "firezone@localhost",
    password: "firezone1234",
    password_confirmation: "firezone1234"
  })

{:ok, device} =
  Devices.create_device(%{
    user_id: user.id,
    name: "Factory Device",
    description: """
    Lorem ipsum dolor sit amet, consectetuer adipiscing elit. Aenean commodo ligula eget dolor. A\
    enean massa. Cum sociis natoque penatibus et magnis dis parturient montes, nascetur ridiculus\
     mus. Donec quam felis, ultricies nec, pellentesque eu, pretium quis, sem. Nulla consequat ma\
    ssa quis enim. Donec pede justo, fringilla vel, aliquet nec, vulputate eget, arcu. In enim ju\
    sto, rhoncus ut, imperdiet a, venenatis vitae, justo. Nullam dictum felis eu pede mollis pret\
    ium. Integer tincidunt. Cras dapibus. Vivamus elementum semper nisi. Aenean vulputate eleifen\
    d tellus. Aenean leo ligula, porttitor eu, consequat vitae, eleifend ac, enim. Aliquam lorem \
    ante, dapibus in, viverra quis, feugiat a, tellus. Phasellus viverra nulla ut metus varius la\
    oreet. Quisque rutrum. Aenean imperdiet. Etiam ultricies nisi vel augue. Curabitur ullamcorpe\
    r ultricies nisi. Nam eget dui. Lorem ipsum dolor sit amet, consectetuer adipiscing elit. Aen\
    ean commodo ligula eget dolor. Aenean massa. Cum sociis natoque penatibus et magnis dis partu\
    rient montes, nascetur ridiculus mus. Donec quam felis, ultricies nec, pellentesque eu, preti\
    um quis, sem. Nulla consequat massa quis enim. Donec pede justo, fringilla vel, aliquet nec, \
    vulputate eget, arcu. In enim justo, rhoncus ut, imperdiet a, venenatis vitae, justo. Nullam \
    dictum felis eu pede mollis pretium. Integer tincidunt. Cras dapibus. Vivamus elementum sempe\
    r nisi. Aenean vulputate eleifend tellus. Aenean leo ligula, porttitor eu, consequat vitae, e\
    leifend ac, enim. Aliquam lorem ante, dapibus in, viverra quis, feugiat a, tellus. Phasellus \
    viverra nulla ut metus varius laoreet. Quisque rutrum. Aenean imperdiet. Etiam ultricies nisi\
     vel augue. Curabitur ullamcorper ultricies nisi. Nam eget dui. Lorem ipsum dolor sit amet, c\
    onsectetuer adipiscing elit. Aenean commodo ligula eget dolor. Aenean massa. Cum sociis natoq\
    ue penatibus et magnis dis parturient montes, nascetur ridiculus mus. Donec quam felis, ultri\
    cies nec, pellentesque eu, pretium quis, sem. Nulla consequat massa quis enim. Donec pede jus\
    to\
    """,
    preshared_key: "27eCDMVvVFfMVS5Rfnn9n7as4M6MemGY/oghmdrwX2E=",
    public_key: "3Fo+SNnDJ6hi8qzPt3nWLwgjCVwvpjHL35qJeatKwEc=",
    remote_ip: %Postgrex.INET{address: {127, 0, 0, 1}},
    rx_bytes: 123_917_823,
    tx_bytes: 1_934_475_211_087_234
  })

{:ok, _connectivity_check} =
  ConnectivityChecks.create_connectivity_check(%{
    response_headers: %{"Content-Type" => "text/plain"},
    response_body: "127.0.0.1",
    response_code: 200,
    url: "https://ping-dev.firez.one/0.1.19"
  })

{:ok, _connectivity_check} =
  ConnectivityChecks.create_connectivity_check(%{
    response_headers: %{"Content-Type" => "text/plain"},
    response_body: "127.0.0.1",
    response_code: 400,
    url: "https://ping-dev.firez.one/0.20.0"
  })
