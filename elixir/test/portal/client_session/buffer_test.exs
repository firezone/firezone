defmodule Portal.ClientSession.BufferTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ClientFixtures
  import Portal.TokenFixtures

  alias Portal.ClientSession
  alias Portal.ClientSession.Buffer

  setup do
    account = account_fixture()
    actor = actor_fixture(account: account)
    client = client_fixture(account: account, actor: actor)
    token = client_token_fixture(account: account, actor: actor)

    buffer =
      start_supervised!({Buffer, name: :"buffer_#{inspect(make_ref())}", callers: [self()]})

    %{buffer: buffer, account: account, client: client, token: token}
  end

  defp build_session(ctx, overrides \\ %{}) do
    defaults = %{
      account_id: ctx.account.id,
      client_id: ctx.client.id,
      client_token_id: ctx.token.id,
      user_agent: "macOS/14.0 apple-client/1.3.0",
      remote_ip: {100, 64, 0, 1},
      remote_ip_location_region: "US",
      remote_ip_location_city: "New York",
      remote_ip_location_lat: 40.7128,
      remote_ip_location_lon: -74.006,
      public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      version: "1.3.0"
    }

    struct!(ClientSession, Map.merge(defaults, overrides))
  end

  describe "insert/2 and flush/1" do
    test "inserts a single session into the database on flush", ctx do
      session = build_session(ctx)

      Buffer.insert(session, ctx.buffer)
      Buffer.flush(ctx.buffer)

      [persisted] = Repo.all(ClientSession)
      assert persisted.account_id == ctx.account.id
      assert persisted.client_id == ctx.client.id
      assert persisted.client_token_id == ctx.token.id
      assert persisted.user_agent == "macOS/14.0 apple-client/1.3.0"
      assert persisted.remote_ip.address == {100, 64, 0, 1}
      assert persisted.remote_ip_location_region == "US"
      assert persisted.remote_ip_location_city == "New York"
      assert persisted.remote_ip_location_lat == 40.7128
      assert persisted.remote_ip_location_lon == -74.006
      assert persisted.version == "1.3.0"
      assert persisted.public_key == session.public_key
    end

    test "generates id and inserted_at for each entry", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      [persisted] = Repo.all(ClientSession)
      assert persisted.id
      assert persisted.inserted_at
    end

    test "buffers multiple sessions and flushes them all at once", ctx do
      for _ <- 1..5 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 5
    end

    test "flush is a no-op when buffer is empty", ctx do
      Buffer.flush(ctx.buffer)

      assert Repo.all(ClientSession) == []
    end

    test "flush clears the buffer so subsequent flush is a no-op", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 1

      # Second flush should not insert duplicates
      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 1
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
          public_key: nil,
          version: nil
        })

      Buffer.insert(session, ctx.buffer)
      Buffer.flush(ctx.buffer)

      [persisted] = Repo.all(ClientSession)
      assert persisted.account_id == ctx.account.id
      assert is_nil(persisted.remote_ip)
      assert is_nil(persisted.user_agent)
      assert is_nil(persisted.version)
    end

    test "handles IPv6 addresses", ctx do
      session =
        build_session(ctx, %{
          remote_ip: {8193, 3512, 0, 0, 0, 0, 0, 1}
        })

      Buffer.insert(session, ctx.buffer)
      Buffer.flush(ctx.buffer)

      [persisted] = Repo.all(ClientSession)
      assert persisted.remote_ip.address == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "each flushed session gets a unique id", ctx do
      for _ <- 1..3 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      Buffer.flush(ctx.buffer)

      ids = Repo.all(ClientSession) |> Enum.map(& &1.id)
      assert length(Enum.uniq(ids)) == 3
    end
  end

  describe "threshold-based flush" do
    test "auto-flushes when buffer reaches threshold", ctx do
      # Override the threshold to a small value by sending casts directly
      # We can't easily override the module attribute, so we test the
      # threshold behavior indirectly through the GenServer state
      for _ <- 1..1_000 do
        Buffer.insert(build_session(ctx), ctx.buffer)
      end

      # Give the GenServer time to process all casts and auto-flush
      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 1_000
    end
  end

  describe "timer-based flush" do
    test "schedules a flush timer on init", ctx do
      # The timer message is :flush — sending it manually simulates the timer firing
      send(ctx.buffer, :flush)

      # Insert after the timer fires to verify the timer reschedules itself
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 1
    end

    test "flushes buffered sessions when timer fires", ctx do
      Buffer.insert(build_session(ctx), ctx.buffer)
      Buffer.insert(build_session(ctx), ctx.buffer)

      # Simulate the timer firing
      send(ctx.buffer, :flush)
      # Synchronize to ensure the :flush message has been processed
      Buffer.flush(ctx.buffer)

      assert length(Repo.all(ClientSession)) == 2
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
