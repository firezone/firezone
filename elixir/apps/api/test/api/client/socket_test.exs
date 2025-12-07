defmodule API.Client.SocketTest do
  use API.ChannelCase, async: true
  import API.Client.Socket, only: [id: 1]
  alias API.Client.Socket

  @geo_headers [
    {"x-geo-location-region", "Ukraine"},
    {"x-geo-location-city", "Kyiv"},
    {"x-geo-location-coordinates", "50.4333,30.5167"}
  ]

  @connect_info %{
    user_agent: "iOS/12.7 connlib/1.3.0",
    peer_data: %{address: {189, 172, 73, 001}},
    x_headers:
      [
        {"x-forwarded-for", "189.172.73.153"}
      ] ++ @geo_headers,
    trace_context_headers: []
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, connect_info: @connect_info) == {:error, :missing_token}
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end

    test "renders error on invalid attrs" do
      context = Fixtures.Auth.build_context(type: :client)
      {_token, encoded_token} = Fixtures.Auth.create_and_encode_token(context: context)

      attrs = %{token: encoded_token}

      assert {:error, changeset} = connect(Socket, attrs, connect_info: @connect_info)

      errors = Domain.Changeset.errors_to_string(changeset)
      assert errors =~ "public_key: can't be blank"
      assert errors =~ "external_id: can't be blank"
    end

    test "returns error when token is created for a different context" do
      context = Fixtures.Auth.build_context(type: :browser)
      {_token, encoded_token} = Fixtures.Auth.create_and_encode_token(context: context)

      attrs = connect_attrs(token: encoded_token)

      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end

    test "creates a new client for user identity" do
      context = Fixtures.Auth.build_context(type: :client)
      {_token, encoded_token} = Fixtures.Auth.create_and_encode_token(context: context)

      attrs = connect_attrs(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info(context))
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == context.user_agent
      assert client.last_seen_remote_ip.address == context.remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "creates a new client for service account identity" do
      context = Fixtures.Auth.build_context(type: :client)
      account = Fixtures.Accounts.create_account()
      actor = Fixtures.Actors.create_actor(type: :service_account, account: account)

      subject = Fixtures.Auth.create_subject(account: account, actor: [type: :account_admin_user])
      in_one_minute = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, encoded_token} =
        Domain.Auth.create_service_account_token(actor, %{"expires_at" => in_one_minute}, subject)

      attrs = connect_attrs(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info(context))
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == context.user_agent
      assert client.last_seen_remote_ip.address == context.remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "propagates trace context" do
      context = Fixtures.Auth.build_context(type: :client)
      {_token, encoded_token} = Fixtures.Auth.create_and_encode_token(context: context)

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      attrs = connect_attrs(token: encoded_token)

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      connect_info = %{connect_info(context) | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "updates existing client" do
      account = Fixtures.Accounts.create_account()
      context = Fixtures.Auth.build_context(type: :client)
      actor = Fixtures.Actors.create_actor(account: account)
      identity = Fixtures.Auth.create_identity(account: account, actor: actor)
      new_identity = Fixtures.Auth.create_identity(account: account, actor: actor)

      {_token, encoded_token} =
        Fixtures.Auth.create_and_encode_token(
          account: account,
          identity: new_identity,
          context: context
        )

      existing_client = Fixtures.Clients.create_client(account: account, identity: identity)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info(context))
      assert client = Repo.one(Domain.Clients.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.identity_id == new_identity.id
    end

    test "uses region code to put default coordinates" do
      account = Fixtures.Accounts.create_account()
      context = Fixtures.Auth.build_context(type: :client)
      identity = Fixtures.Auth.create_identity(account: account)

      {_token, encoded_token} =
        Fixtures.Auth.create_and_encode_token(
          account: account,
          identity: identity,
          context: context
        )

      existing_client = Fixtures.Clients.create_client(account: account, identity: identity)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)

      connect_info = %{connect_info(context) | x_headers: [{"x-geo-location-region", "UA"}]}

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Repo.one(Domain.Clients.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "UA"
      assert client.last_seen_remote_ip_location_city == nil
      assert client.last_seen_remote_ip_location_lat == 49.0
      assert client.last_seen_remote_ip_location_lon == 32.0
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      subject = Fixtures.Auth.create_subject(type: :client)
      socket = socket(API.Client.Socket, "", %{subject: subject})

      assert id(socket) == "sessions:#{subject.token_id}"
    end
  end

  defp connect_info(context) do
    %{
      user_agent: context.user_agent,
      peer_data: %{address: context.remote_ip},
      x_headers: @geo_headers,
      trace_context_headers: []
    }
  end

  defp connect_attrs(attrs) do
    Fixtures.Clients.client_attrs()
    |> Map.take(~w[external_id public_key]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
