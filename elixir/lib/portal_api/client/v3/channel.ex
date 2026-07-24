defmodule PortalAPI.Client.V3.Channel do
  use PortalAPI, :channel
  alias PortalAPI.Client.Channel.Shared
  alias PortalAPI.Client.DeviceTrust
  alias PortalAPI.Client.Socket
  require Logger

  # On gated accounts the device is not resolved yet when the channel joins:
  # the client is challenged to prove possession of an MDM-provisioned
  # certificate first, and the device is resolved (attested-first) only after
  # the response or the timeout. Failure never blocks the connect - it falls
  # back to the plain firezone_id path, unverified.

  @impl true
  def join(topic, payload, socket) do
    socket = assign(socket, :channel_protocol, __MODULE__)

    if socket.assigns[:pending_device] do
      send(self(), :push_device_trust_request)
      {:ok, socket}
    else
      Shared.join(topic, payload, socket)
    end
  end

  @impl true
  defdelegate terminate(reason, socket), to: Shared

  @impl true
  def handle_info(:push_device_trust_request, socket) do
    nonce = DeviceTrust.nonce()
    push(socket, "device_trust_request", DeviceTrust.challenge_payload(nonce))
    Process.send_after(self(), :device_trust_timeout, challenge_timeout_ms())

    {:noreply, assign(socket, :device_trust_nonce, nonce)}
  end

  def handle_info(:device_trust_timeout, socket) do
    if socket.assigns[:pending_device] do
      Logger.info("Device trust challenge timed out; connecting without attestation",
        account_id: socket.assigns.subject.account.id
      )

      socket = assign(socket, :device_trust_nonce, nil)
      resolve_and_continue(socket, nil)
    else
      {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: Shared.handle_info(message, socket)

  @impl true
  def handle_in("device_trust_response", payload, socket) do
    nonce = socket.assigns[:device_trust_nonce]
    socket = assign(socket, :device_trust_nonce, nil)

    cond do
      is_nil(socket.assigns[:pending_device]) ->
        Logger.debug("Ignoring late or duplicate device trust response")
        {:noreply, socket}

      is_nil(nonce) ->
        Logger.debug("Ignoring device trust response without an outstanding challenge")
        {:noreply, socket}

      true ->
        account_id = socket.assigns.subject.account.id
        anchors = socket.assigns.pending_device.anchors

        verified =
          case DeviceTrust.verify_response(payload, nonce, anchors) do
            {:ok, verified} ->
              Logger.info("Device trust challenge succeeded",
                account_id: account_id,
                last_attested_cert_fingerprint: verified.last_attested_cert_fingerprint,
                identifiers: inspect(verified.identifiers)
              )

              verified

            {:error, :no_usable_cert} ->
              Logger.info(
                "Device trust challenge: no usable certificate presented (device not enrolled?)",
                account_id: account_id
              )

              nil

            {:error, :verification_failed} ->
              Logger.warning(
                "Device trust challenge failed verification (check trust anchor configuration)",
                account_id: account_id
              )

              nil
          end

        resolve_and_continue(socket, verified)
    end
  end

  def handle_in(message, payload, socket), do: Shared.handle_in(message, payload, socket)

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"

  defp resolve_and_continue(socket, verified) do
    # Whether THIS session proved possession is live connection state, not row
    # state: it rides the socket assigns and the presence metadata, while the
    # last_attested_* columns record durable history.
    socket = assign(socket, :attested?, not is_nil(verified))

    case Socket.resolve_deferred_client(socket, verified) do
      {:ok, socket} ->
        send(self(), :after_join)
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning(
          "Failed to resolve client after device trust challenge: #{inspect(reason)}",
          account_id: socket.assigns.subject.account.id
        )

        {:stop, :shutdown, socket}
    end
  end

  defp challenge_timeout_ms do
    Portal.Config.get_env(:portal, :device_trust_challenge_timeout_ms, :timer.seconds(10))
  end
end
