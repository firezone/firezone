defmodule PortalAPI.Device.Channel.Ice do
  @moduledoc """
  ICE candidate relay between device channels.

  A device hands its channel the candidates it gathered and the peers that
  need them; the channel delivers them to each peer's channel through
  `Portal.PG`, keyed by device ID, and the peer's channel pushes them on.
  The messages a channel receives name the sending device; which key the
  payload uses for it is the channel protocol's choice.
  """

  import Phoenix.Channel, only: [push: 3]

  alias Portal.PG

  @typedoc "A PG message carrying candidates from one device to another."
  @type message :: {atom(), Ecto.UUID.t(), [String.t()]}

  @doc """
  Sends `{tag, from_id, candidates}` to the channel of every device in
  `target_ids`. A target that is not connected is skipped: candidates are
  best effort and the sender learns about an absent peer through ICE itself.
  """
  @spec broadcast([Ecto.UUID.t()], atom(), Ecto.UUID.t(), [String.t()]) :: :ok
  def broadcast(target_ids, tag, from_id, candidates) do
    Enum.each(target_ids, fn target_id ->
      PG.deliver(target_id, {tag, from_id, candidates})
    end)
  end

  @doc "Sends `{tag, from_id, candidates}` to one device's channel, saying whether it is connected."
  @spec deliver(Ecto.UUID.t(), atom(), Ecto.UUID.t(), [String.t()]) :: :ok | {:error, :not_found}
  def deliver(target_id, tag, from_id, candidates) do
    PG.deliver(target_id, {tag, from_id, candidates})
  end

  @doc "Pushes candidates received from `peer_id` to the device, naming the peer under `peer_key`."
  @spec push_candidates(Phoenix.Socket.t(), String.t(), atom(), Ecto.UUID.t(), [String.t()]) ::
          {:noreply, Phoenix.Socket.t()}
  def push_candidates(socket, event, peer_key, peer_id, candidates) do
    push(socket, event, %{peer_key => peer_id, candidates: candidates})

    {:noreply, socket}
  end
end
