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
    user_agent: "iOS/12.7 (iPhone) connlib/0.1.1",
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
      subject = Fixtures.Auth.create_subject()
      {:ok, token} = Auth.create_session_token_from_subject(subject)

      attrs = %{token: token}

      assert {:error, changeset} = connect(Socket, attrs, connect_info: connect_info(subject))

      errors = API.Sockets.changeset_error_to_string(changeset)
      assert errors =~ "public_key: can't be blank"
      assert errors =~ "external_id: can't be blank"
    end

    test "does not allow to use tokens from other contexts" do
      subject = Fixtures.Auth.create_subject(context: [type: :browser])
      token = Domain.Tokens.encode_token!(subject.token)

      attrs = connect_attrs(token: token)

      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end

    test "creates a new client" do
      subject = Fixtures.Auth.create_subject(context: [type: :client])
      token = Domain.Tokens.encode_token!(subject.token)

      attrs = connect_attrs(token: token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info(subject))
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == subject.context.user_agent
      assert client.last_seen_remote_ip.address == subject.context.remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "0.7.412"
    end

    test "propagates trace context" do
      subject = Fixtures.Auth.create_subject(context: [type: :client])
      token = Domain.Tokens.encode_token!(subject.token)

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      attrs = connect_attrs(token: token)

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      connect_info = %{connect_info(subject) | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "updates existing client" do
      subject = Fixtures.Auth.create_subject(context: [type: :client])
      existing_client = Fixtures.Clients.create_client(subject: subject)
      token = Domain.Tokens.encode_token!(subject.token)

      attrs = connect_attrs(token: token, external_id: existing_client.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info(subject))
      assert client = Repo.one(Domain.Clients.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
    end

    test "uses region code to put default coordinates" do
      subject = Fixtures.Auth.create_subject(context: [type: :client])
      existing_client = Fixtures.Clients.create_client(subject: subject)
      token = Domain.Tokens.encode_token!(subject.token)

      attrs = connect_attrs(token: token, external_id: existing_client.external_id)

      connect_info = %{connect_info(subject) | x_headers: [{"x-geo-location-region", "UA"}]}

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
      client = Fixtures.Clients.create_client()
      socket = socket(API.Client.Socket, "", %{client: client})

      assert id(socket) == "client:#{client.id}"
    end
  end

  defp connect_info(subject) do
    %{
      user_agent: subject.context.user_agent,
      peer_data: %{address: subject.context.remote_ip},
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
