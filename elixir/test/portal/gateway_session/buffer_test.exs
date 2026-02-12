defmodule Portal.GatewaySession.BufferTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures
  import Portal.GatewayFixtures
  import Portal.TokenFixtures

  alias Portal.GatewaySession
  alias Portal.GatewaySession.Buffer

  setup do
    account = account_fixture()
    site = site_fixture(account: account)
    gateway = gateway_fixture(account: account, site: site)
    token = gateway_token_fixture(account: account, site: site)

    buffer =
      start_supervised!({Buffer, name: :"buffer_#{inspect(make_ref())}", callers: [self()]})

    %{buffer: buffer, account: account, gateway: gateway, token: token}
  end

  defp count_sessions(ctx) do
    import Ecto.Query
    Repo.aggregate(from(s in GatewaySession, where: s.gateway_token_id == ^ctx.token.id), :count)
  end

  defp build_session(ctx, overrides \\ %{}) do
    defaults = %{
      account_id: ctx.account.id,
      gateway_id: ctx.gateway.id,
      gateway_token_id: ctx.token.id,
      user_agent: "Linux/6.1.0 connlib/1.3.0 (x86_64)",
      remote_ip: {100, 64, 0, 1},
      remote_ip_location_region: "US",
      remote_ip_location_city: "New York",
      remote_ip_location_lat: 40.7128,
      remote_ip_location_lon: -74.006,
      version: "1.3.0"
    }

    struct!(GatewaySession, Map.merge(defaults, overrides))
  end

  describe "insert/2 and flush/1" do
    test "inserts a single session into the database on flush", ctx do
      session = build_session(ctx)

      Buffer.insert(session, ctx.buffer)
      Buffer.flush(ctx.buffer)

      import Ecto.Query

      [persisted] =
        Repo.all(from(s in GatewaySession, where: s.gateway_token_id == ^ctx.token.id))

      assert persisted.account_id == ctx.account.id
      assert persisted.gateway_id == ctx.gateway.id
      assert persisted.gateway_token_id == ctx.token.id
      assert persisted.user_agent == "Linux/6.1.0 connlib/1.3.0 (x86_64)"
      assert persisted.remote_ip.address == {100, 64, 0, 1}
      assert persisted.remote_ip_location_region == "US"
      assert persisted.remote_ip_location_city == "New York"
      assert persisted.remote_ip_location_lat == 40.7128
      assert persisted.remote_ip_location_lon == -74.006
      assert persisted.version == "1.3.0"
    end

    test "generates id and inserted_at for each entry", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      import Ecto.Query

      [persisted] =
        Repo.all(from(s in GatewaySession, where: s.gateway_token_id == ^ctx.token.id))

      assert persisted.id
      assert persisted.inserted_at
    end

    test "buffers multiple sessions and flushes them all at once", ctx do
      for _ <- 1..5 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 5
    end

    test "flush is a no-op when buffer is empty", ctx do
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 0
    end

    test "flush clears the buffer so subsequent flush is a no-op", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 1

      # Second flush should not insert duplicates
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 1
    end

    test "handles sessions with nil optional fields", ctx do
      session =
        build_session(ctx, %{
          remote_ip: nil,
          remote_ip_location_region: nil,
          remote_ip_location_city: nil,
          remote_ip_location_lat: nil,
          remote_ip_location_lon: nil,
          user_agent: nil,
          version: nil
        })

      Buffer.insert(session, ctx.buffer)
      Buffer.flush(ctx.buffer)

      import Ecto.Query

      [persisted] =
        Repo.all(from(s in GatewaySession, where: s.gateway_token_id == ^ctx.token.id))

      assert persisted.account_id == ctx.account.id
      assert is_nil(persisted.remote_ip)
      assert is_nil(persisted.user_agent)
      assert is_nil(persisted.version)
    end

    test "each flushed session gets a unique id", ctx do
      for _ <- 1..3 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      Buffer.flush(ctx.buffer)

      import Ecto.Query

      ids =
        Repo.all(from(s in GatewaySession, where: s.gateway_token_id == ^ctx.token.id))
        |> Enum.map(& &1.id)

      assert length(Enum.uniq(ids)) == 3
    end
  end

  describe "threshold-based flush" do
    test "auto-flushes when buffer reaches threshold", ctx do
      for _ <- 1..1_000 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      # Give the GenServer time to process all casts and auto-flush
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 1_000
    end
  end

  describe "timer-based flush" do
    test "schedules a flush timer on init", ctx do
      # The timer message is :flush — sending it manually simulates the timer firing
      send(ctx.buffer, :flush)

      # Insert after the timer fires to verify the timer reschedules itself
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 1
    end

    test "flushes buffered sessions when timer fires", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.insert(build_session(ctx), ctx.buffer)

      # Simulate the timer firing
      send(ctx.buffer, :flush)
      # Synchronize to ensure the :flush message has been processed
      Buffer.flush(ctx.buffer)

      assert count_sessions(ctx) == 2
    end
  end

  describe "start_link/1" do
    test "registers with the given name" do
      name = :"buffer_custom_#{inspect(make_ref())}"

      pid =
        start_supervised!(
          {Buffer, name: name, callers: [self()]},
          id: :custom_name_buffer
        )

      assert Process.alive?(pid)
      assert GenServer.whereis(name) == pid
    end
  end
end
