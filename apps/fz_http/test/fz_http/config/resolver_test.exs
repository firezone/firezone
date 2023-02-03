defmodule FzHttp.Config.ResolverTest do
  use ExUnit.Case, async: true
  import FzHttp.Config.Resolver

  describe "resolve/4" do
    test "returns nil when variable is not found" do
      env_configurations = %{}
      db_configurations = %{}

      assert resolve(:foo, env_configurations, db_configurations, []) == :error
    end

    test "returns default value when variable is not found" do
      env_configurations = %{}
      db_configurations = %{}
      opts = [default: :foo]

      assert resolve(:foo, env_configurations, db_configurations, opts) == {:ok, {:default, :foo}}
    end

    test "returns variable from system environment" do
      env_configurations = %{"FOO" => "bar"}
      db_configurations = %{}

      assert resolve(:foo, env_configurations, db_configurations, []) ==
               {:ok, {{:env, "FOO"}, "bar"}}
    end

    test "returns variable from system environment with legacy key" do
      env_configurations = %{"FOO" => "bar"}
      db_configurations = %{}
      opts = [legacy_keys: [{:env, "FOO", "1.0"}]]

      assert resolve(:bar, env_configurations, db_configurations, opts) ==
               {:ok, {{:env, "FOO"}, "bar"}}
    end

    test "returns variable from database" do
      env_configurations = %{}
      db_configurations = %FzHttp.Configurations.Configuration{default_client_dns: "1.2.3.4"}

      assert resolve(:default_client_dns, env_configurations, db_configurations, []) ==
               {:ok, {{:db, :default_client_dns}, "1.2.3.4"}}
    end

    test "precedence" do
      key = :my_key
      env = %{"FOO" => "3.3.2.2"}
      db = %{}

      # `nil` by default
      opts = []
      assert resolve(key, env, db, opts) == :error

      # `default` opt overrides `nil`
      opts = [default: "8.8.4.4"]
      assert resolve(key, env, db, opts) == {:ok, {:default, "8.8.4.4"}}

      # DB value overrides default
      db = %{my_key: "1.2.3.4"}
      assert resolve(key, env, db, opts) == {:ok, {{:db, key}, "1.2.3.4"}}

      # Legacy env overrides DB
      opts = [legacy_keys: [{:env, "FOO", "1.0"}]]
      assert resolve(key, env, db, opts) == {:ok, {{:env, "FOO"}, "3.3.2.2"}}

      # Env overrides legacy env
      env = Map.merge(env, %{"MY_KEY" => "2.7.2.8"})
      assert resolve(key, env, db, opts) == {:ok, {{:env, "MY_KEY"}, "2.7.2.8"}}
    end
  end
end
