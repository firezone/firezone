defmodule Portal.Config.ResolverTest do
  use ExUnit.Case, async: true
  import Portal.Config.Resolver

  describe "resolve/4" do
    test "returns nil when variable is not found" do
      env_var_to_configurations = %{}

      assert resolve(:foo, env_var_to_configurations, []) == :error
    end

    test "returns default value when variable is not found" do
      env_var_to_configurations = %{}
      opts = [default: :foo]

      assert resolve(:foo, env_var_to_configurations, opts) == {:ok, {:default, :foo}}
    end

    test "returns variable from system environment" do
      env_var_to_configurations = %{"FOO" => "bar"}

      assert resolve(:foo, env_var_to_configurations, []) ==
               {:ok, {{:env, "FOO"}, "bar"}}
    end

    test "precedence" do
      key = :my_key
      env = %{"FOO" => "3.3.2.2"}

      # `nil` by default
      opts = []
      assert resolve(key, env, opts) == :error

      # `default` opt overrides `nil`
      opts = [default: "8.8.4.4"]
      assert resolve(key, env, opts) == {:ok, {:default, "8.8.4.4"}}

      # Env overrides default
      env = Map.merge(env, %{"MY_KEY" => "2.7.2.8"})
      assert resolve(key, env, opts) == {:ok, {{:env, "MY_KEY"}, "2.7.2.8"}}
    end
  end
end
