defmodule API.Client.SocketTest do
  use API.ChannelCase, async: true
  import API.Client.Socket, only: [id: 1]
  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.TokenFixtures
  import Domain.ClientFixtures
  import Domain.SubjectFixtures
  alias API.Client.Socket

  @geo_headers [
    {"x-geo-location-region", "Ukraine"},
    {"x-geo-location-city", "Kyiv"},
    {"x-geo-location-coordinates", "50.4333,30.5167"}
  ]

  # The actual client IP from x-forwarded-for header
  @client_remote_ip {189, 172, 73, 153}

  @connect_info %{
    user_agent: "iOS/12.7 connlib/1.3.0",
    # Proxy IP (not the client's actual IP)
    peer_data: %{address: {189, 172, 73, 1}},
    x_headers:
      [
        # Original client IP - this is the address that should be used
        {"x-forwarded-for", :inet.ntoa(@client_remote_ip) |> to_string()}
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
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = %{"token" => encoded_token}

      assert {:error, changeset} = connect(Socket, attrs, connect_info: @connect_info)

      errors = Domain.Changeset.errors_to_string(changeset)
      assert errors =~ "public_key: can't be blank"
      assert errors =~ "external_id: can't be blank"
    end

    test "returns error when token is created for a different context" do
      # api_client tokens should not be usable for client socket
      token = api_client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)

      assert connect(Socket, attrs, connect_info: @connect_info) == {:error, :invalid_token}
    end

    test "creates a new client for user identity" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == @connect_info.user_agent
      assert client.last_seen_remote_ip.address == @client_remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "creates a new client for service account identity" do
      account = account_fixture()
      actor = actor_fixture(account: account, type: :service_account)
      admin_subject = subject_fixture(account: account, actor: %{type: :account_admin_user})

      in_one_minute = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, encoded_token} =
        Domain.Auth.create_service_account_token(
          actor,
          %{"expires_at" => in_one_minute},
          admin_subject
        )

      attrs = connect_attrs(token: encoded_token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert client = Map.fetch!(socket.assigns, :client)

      assert client.external_id == attrs["external_id"]
      assert client.public_key == attrs["public_key"]
      assert client.last_seen_user_agent == @connect_info.user_agent
      assert client.last_seen_remote_ip.address == @client_remote_ip
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
      assert client.last_seen_version == "1.3.0"
    end

    test "propagates trace context" do
      token = client_token_fixture()
      encoded_token = encode_token(token)

      span_ctx = OpenTelemetry.Tracer.start_span("test")
      OpenTelemetry.Tracer.set_current_span(span_ctx)

      attrs = connect_attrs(token: encoded_token)

      trace_context_headers = [
        {"traceparent", "00-a1bf53221e0be8000000000000000002-f316927eb144aa62-01"}
      ]

      connect_info = %{@connect_info | trace_context_headers: trace_context_headers}

      assert {:ok, _socket} = connect(Socket, attrs, connect_info: connect_info)
      assert span_ctx != OpenTelemetry.Tracer.current_span_ctx()
    end

    test "updates existing client" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info: @connect_info)
      assert client = Repo.one(Domain.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "Ukraine"
      assert client.last_seen_remote_ip_location_city == "Kyiv"
      assert client.last_seen_remote_ip_location_lat == 50.4333
      assert client.last_seen_remote_ip_location_lon == 30.5167
    end

    test "uses region code to put default coordinates" do
      account = account_fixture()
      actor = actor_fixture(account: account)

      # Create existing client
      existing_client = client_fixture(account: account, actor: actor)

      # Create a new token for same actor
      token = client_token_fixture(account: account, actor: actor)
      encoded_token = encode_token(token)

      attrs = connect_attrs(token: encoded_token, external_id: existing_client.external_id)

      connect_info = %{@connect_info | x_headers: [{"x-geo-location-region", "UA"}]}

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert client = Repo.one(Domain.Client)
      assert client.id == socket.assigns.client.id
      assert client.last_seen_remote_ip_location_region == "UA"
      assert client.last_seen_remote_ip_location_city == nil
      assert client.last_seen_remote_ip_location_lat == 49.0
      assert client.last_seen_remote_ip_location_lon == 32.0
    end
  end

  describe "id/1" do
    test "creates a channel for a client" do
      subject = subject_fixture(type: :client)
      socket = socket(API.Client.Socket, "", %{subject: subject})

      assert id(socket) == "socket:#{subject.auth_ref.id}"
    end
  end

  defp connect_attrs(attrs) do
    valid_client_attrs()
    |> Map.take([:external_id, :public_key])
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
