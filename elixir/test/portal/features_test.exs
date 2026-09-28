defmodule Portal.FeaturesTest do
  use Portal.DataCase, async: true

  import Portal.FeaturesFixtures

  for feature <- [:x509_auth, :aes_gcm] do
    test "enabled?/1 reads the #{feature} global rollout flag" do
      disable_feature(unquote(feature))
      refute Portal.Features.enabled?(unquote(feature))

      enable_feature(unquote(feature))
      assert Portal.Features.enabled?(unquote(feature))
    end
  end

  # The cache is shared by all tests, so these use `:x509_auth`, which nothing
  # else reads through it.
  describe "cached_enabled?/1" do
    test "reads through to the database when the cache is disabled" do
      Portal.Config.put_env_override(:portal, Portal.Features, cache_ttl: 0)

      enable_feature(:x509_auth)
      assert Portal.Features.cached_enabled?(:x509_auth)

      disable_feature(:x509_auth)
      refute Portal.Features.cached_enabled?(:x509_auth)
    end

    test "serves the cached value until the TTL expires" do
      Portal.Config.put_env_override(:portal, Portal.Features, cache_ttl: 0)
      enable_feature(:x509_auth)
      assert Portal.Features.cached_enabled?(:x509_auth)

      Portal.Config.put_env_override(:portal, Portal.Features, cache_ttl: :timer.minutes(1))
      disable_feature(:x509_auth)
      assert Portal.Features.cached_enabled?(:x509_auth)

      Portal.Config.put_env_override(:portal, Portal.Features, cache_ttl: 0)
      refute Portal.Features.cached_enabled?(:x509_auth)
    end
  end
end
