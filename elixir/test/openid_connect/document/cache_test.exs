defmodule OpenIDConnect.Document.CacheTest do
  use ExUnit.Case, async: true
  import OpenIDConnect.Document.Cache

  @valid_document %OpenIDConnect.Document{
    authorization_endpoint: "https://common.auth0.com/authorize",
    claims_supported: [
      "aud",
      "auth_time",
      "created_at",
      "email",
      "email_verified",
      "exp",
      "family_name",
      "given_name",
      "iat",
      "identities",
      "iss",
      "name",
      "nickname",
      "phone_number",
      "picture",
      "sub"
    ],
    end_session_endpoint: nil,
    expires_at: DateTime.utc_now(),
    jwks: %JOSE.JWK{},
    raw: "",
    response_types_supported: [
      "code",
      "token",
      "id_token",
      "code token",
      "code id_token",
      "id_token token",
      "code id_token token"
    ],
    token_endpoint: "https://common.auth0.com/oauth/token"
  }

  describe "put/2" do
    test "persists a documents to the cache" do
      uri = uniq_uri()
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}

      put(uri, document)

      assert %{^uri => {_ref, _last_fetched_at, _last_refresh_at, ^document}} = flush()
    end

    test "does not persist expired documents" do
      uri = uniq_uri()
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)}

      put(uri, document)

      refute Map.has_key?(flush(), uri)
    end

    test "schedules document removal and removes it once it's expired" do
      uri = uniq_uri()
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}

      put(uri, document)

      assert %{^uri => {ref, _last_fetched_at, _last_refresh_at, _document}} = flush()
      assert Process.read_timer(ref) in 58_000..62_000

      send(OpenIDConnect.Document.Cache, {:remove, uri})
      refute Map.has_key?(flush(), uri)
    end
  end

  describe "fetch/1" do
    test "returns error when there is no cache" do
      uri = uniq_uri()
      assert fetch(uri) == :error
    end

    test "returns cached documents" do
      uri = uniq_uri()
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}
      put(uri, document)

      assert {:ok, cached_document} = fetch(uri)
      assert document == cached_document
    end

    test "does not return documents that already expired" do
      uri = uniq_uri()
      now = DateTime.utc_now()
      document = %{@valid_document | expires_at: DateTime.add(now, -1, :second)}
      timer_ref = Process.send_after(self(), :ignored, :timer.seconds(60))
      state = %{uri => {timer_ref, now, nil, document}}

      assert handle_call({:fetch, uri}, self(), state) == {:reply, :error, %{}}
    end

    test "evicting an expired entry drains a stale {:remove, uri} queued behind the :fetch call" do
      # Same race as `:expire`, but tripped when `:fetch` finds an expired doc.
      {:ok, pid} = start_link(name: :fetch_race_test)
      uri = uniq_uri()

      # `put/2` rejects expired docs, so put a fresh one and swap in expired via :sys.replace_state.
      fresh = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}
      expired = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)}
      put(pid, uri, fresh)

      :sys.replace_state(pid, fn state ->
        Map.update!(state, uri, fn {ref, fetched_at, refresh_at, _doc} ->
          {ref, fetched_at, refresh_at, expired}
        end)
      end)

      :sys.suspend(pid)

      parent = self()
      spawn_link(fn -> send(parent, {:fetch_result, fetch(pid, uri)}) end)

      wait_for_mailbox(pid, 1)
      send(pid, {:remove, uri})
      assert {:message_queue_len, 2} = Process.info(pid, :message_queue_len)

      :sys.resume(pid)
      assert_receive {:fetch_result, :error}

      # Without the drain, the queued `{:remove, uri}` would wipe this fresh put.
      put(pid, uri, fresh)
      assert %{^uri => _} = flush(pid)
    end
  end

  describe "clear/1" do
    test "clears the cache and returns :ok" do
      {:ok, pid} = start_link(name: :clear_test1)
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}

      put(pid, uniq_uri(), document)
      put(pid, uniq_uri(), document)

      assert Enum.count(flush(pid)) == 2
      assert clear(pid) == :ok
      assert flush(pid) == %{}
    end

    test "cancels all scheduled timers" do
      {:ok, pid} = start_link(name: :clear_test2)
      uri = uniq_uri()
      document = %{@valid_document | expires_at: DateTime.utc_now() |> DateTime.add(60, :second)}

      put(pid, uri, document)

      assert %{^uri => {timer_ref, _last_fetched_at, _last_refresh_at, _document}} = flush(pid)
      assert Process.read_timer(timer_ref)

      assert clear(pid) == :ok
      assert Process.read_timer(timer_ref) == false
    end

    test "works on an empty cache" do
      {:ok, pid} = start_link(name: :clear_test3)
      assert clear(pid) == :ok
      assert flush(pid) == %{}
    end
  end

  describe ":gc" do
    test "doesn't do anything when cache is empty" do
      {:ok, pid} = start_link(name: :gc_test1)
      assert Enum.empty?(flush(pid))
      send(pid, :gc)
      assert flush(pid) == %{}
    end

    test "removes excessive entries from cache" do
      {:ok, pid} = start_link(name: :gc_test2)

      documents =
        for i <- 1..2000 do
          expires_at = DateTime.utc_now() |> DateTime.add(60 + i, :second)
          document = %{@valid_document | expires_at: expires_at}
          put(pid, uniq_uri(), document)
          document
        end

      assert Enum.count(flush(pid)) == 2000

      send(pid, :gc)

      assert state = flush(pid)
      assert Enum.count(state) == 1000

      {_uri, {_ref, _last_fetched_at, _last_refresh_at, document}} =
        Enum.min_by(
          state,
          fn {_uri, {_ref, last_fetched_at, _last_refresh_at, _document}} ->
            last_fetched_at
          end,
          DateTime
        )

      assert document.expires_at == Enum.at(documents, 1000).expires_at
    end
  end

  defp uniq_uri, do: "http://example.com:#{System.unique_integer([:positive])}"

  defp wait_for_mailbox(pid, expected_len, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_mailbox(pid, expected_len, deadline)
  end

  defp do_wait_for_mailbox(pid, expected_len, deadline) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len >= expected_len ->
        :ok

      info ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(
            "wait_for_mailbox timed out waiting for mailbox length >= #{expected_len} on " <>
              "#{inspect(pid)} (got: #{inspect(info)})"
          )
        else
          Process.sleep(1)
          do_wait_for_mailbox(pid, expected_len, deadline)
        end
    end
  end
end
