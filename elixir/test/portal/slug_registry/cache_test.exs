defmodule Portal.SlugRegistry.CacheTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Portal.SlugRegistryHelpers

  alias Portal.SlugRegistry.Cache

  setup do
    use_azure_registry(:us)
    test_pid = self()

    stub_registry(fn conn ->
      send(test_pid, :registry_read)
      send_resp(conn, 404, "")
    end)

    %{slug: "cache_#{System.unique_integer([:positive])}"}
  end

  describe "lookup/1" do
    test "remembers a miss", %{slug: slug} do
      assert Cache.lookup(slug) == :not_found
      assert Cache.lookup(slug) == :not_found

      assert_received :registry_read
      refute_received :registry_read
    end

    test "stops remembering once the cache is full", %{slug: slug} do
      Portal.Config.put_env_override(Cache, max_entries: 0)

      assert Cache.lookup(slug) == :not_found
      assert Cache.lookup(slug) == :not_found

      assert_received :registry_read
      assert_received :registry_read
    end
  end

  describe "sweep" do
    test "drops expired entries and keeps fresh ones", %{slug: slug} do
      now = System.monotonic_time(:millisecond)
      :ets.insert(Cache, {slug <> "_expired", :not_found, now - 1})
      :ets.insert(Cache, {slug <> "_fresh", :not_found, now + :timer.minutes(1)})

      send(Cache, :sweep)
      :sys.get_state(Cache)

      assert :ets.lookup(Cache, slug <> "_expired") == []
      assert [_] = :ets.lookup(Cache, slug <> "_fresh")
    end
  end
end
