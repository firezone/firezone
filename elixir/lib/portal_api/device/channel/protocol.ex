defmodule PortalAPI.Device.Channel.Protocol do
  @moduledoc """
  What a channel protocol tells the core about itself.

  Every device talks to the portal through `PortalAPI.Device.Channel.Core`.
  The module a socket names as its channel is an adapter over the core: it
  renames the messages its deployed binaries expect, picks the views that
  render payloads for its version, and says how the device acknowledges an
  authorization. Everything else, who may reach what and who serves whom,
  lives in the core and is the same on every protocol.
  """

  @typedoc """
  Which of the two legacy sockets the protocol descends from, which decides
  the shape of its init payload and which deprecated paths it still serves.
  `:device` is the unified protocol with both halves.
  """
  @type kind :: :client | :gateway | :device

  @doc "The protocol version the device speaks, as its socket path numbers it."
  @callback protocol_version() :: pos_integer()

  @doc "See `t:kind/0`."
  @callback kind() :: kind()

  @doc """
  The socket assign the device arrived under. The core keeps the device
  there as well as under `:device`, so code written against the old
  name keeps reading the current struct.
  """
  @callback device_key() :: atom()

  @doc """
  Whether the device consumes resources: it gets the outbound view, asks
  for authorizations and is told about resource changes.
  """
  @callback outbound?() :: boolean()

  @doc """
  What happens when a second connection for the same device registers.
  Deployed gateways exit for good on any `disconnect`, so their protocols
  keep first-wins; the newcomer is cut.
  """
  @callback registration() :: :first_wins | :last_wins

  @doc """
  How the device acknowledges an authorization it received: by echoing the
  signed ref after installing it, or not at all, in which case the channel
  acknowledges on its behalf the moment the payload is on the socket.
  """
  @callback ack_mode() :: :device_echo | :auto

  @doc "The event an authorization is pushed to this device under, when it is the receiver."
  @callback create_authorization_event() :: String.t()

  @doc "The event the initiator hears when its authorization was accepted."
  @callback authorization_created_event() :: String.t()

  @doc "The event the initiator hears when its authorization could not be created."
  @callback authorization_creation_failed_event() :: String.t()
end
