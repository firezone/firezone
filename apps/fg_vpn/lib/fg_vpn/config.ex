defmodule FgVpn.Config do
  @moduledoc """
  Functions for reading / writing the WireGuard config
  """

  alias Phoenix.PubSub
  use GenServer

  @begin_sentinel "# BEGIN FIREGUARD-MANAGED PEER LIST"
  @end_sentinel "# END FIREGUARD-MANAGED PEER LIST"

  def start_link(_) do
    peers = read()
    GenServer.start_link(__MODULE__, peers)
  end

  @impl true
  def init(peers) do
    # Subscribe to PubSub from FgHttp application
    {PubSub.subscribe(:fg_http_pub_sub, "config"), peers}
  end

  @impl true
  def handle_info({:verify_device, pubkey}, pubkeys) do
    new_peers = [pubkey | pubkeys]
    write!(new_peers)
    {:noreply, new_peers}
  end

  @impl true
  def handle_info({:remove_device, pubkey}, pubkeys) do
    new_peers = List.delete(pubkeys, pubkey)
    write!(new_peers)
    {:noreply, new_peers}
  end

  @doc """
  Writes configuration file.
  """
  def write!(peers) do
    Application.get_env(:fg_vpn, :wireguard_conf_path)
    |> File.write!(render(peers))
  end

  @doc """
  Reads configuration file and generates a list of pubkeys
  """
  def read do
    path = Application.get_env(:fg_vpn, :wireguard_conf_path)

    case File.read(path) do
      {:ok, str} ->
        str
        |> String.split(@begin_sentinel)
        |> List.last()
        |> String.split(@end_sentinel)
        |> List.first()
        |> extract_pubkeys()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Extracts pubkeys from a configuration file snippet
  """
  def extract_pubkeys(conf_section) do
    ~r/PublicKey = (.*)/
    |> Regex.scan(conf_section)
    |> Enum.map(fn match_list -> List.last(match_list) end)
  end

  @doc """
  Renders WireGuard config in a deterministic way.
  """
  def render(peers) do
    @begin_sentinel <> "\n" <> peers_to_config(peers) <> @end_sentinel
  end

  defp peers_to_config(peers) do
    Enum.map_join(peers, fn pubkey ->
      ~s"""
      # BEGIN PEER #{pubkey}
      [Peer]
      PublicKey = #{pubkey}
      AllowedIPs = 0.0.0.0/0, ::/0
      # END PEER #{pubkey}
      """
    end)
  end
end
