defmodule API.Client.Presence do
  use Phoenix.Presence,
    otp_app: :api,
    pubsub_server: Domain.PubSub
end
