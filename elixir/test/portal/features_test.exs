defmodule Portal.FeaturesTest do
  use Portal.DataCase, async: true

  import Portal.FeaturesFixtures

  for feature <- [:trust_anchors, :device_posture, :mcp] do
    test "enabled?/1 reads the #{feature} global rollout flag" do
      disable_feature(unquote(feature))
      refute Portal.Features.enabled?(unquote(feature))

      enable_feature(unquote(feature))
      assert Portal.Features.enabled?(unquote(feature))
    end
  end
end
