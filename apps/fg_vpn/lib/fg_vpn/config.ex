defmodule FgVpn.Config do
  @moduledoc """
  Functions for reading / writing the WireGuard config
  """

  alias FgVpn.CLI
  alias Phoenix.PubSub
  use GenServer

  @config_header """
  # This file is being managed by the fireguard systemd service. Any changes
  # will be overwritten eventually.

  """

  def start_link(_) do
    # Load existing config from file then write it so we start with a clean slate.
    config = read_and_rewrite_config()
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config) do
    # Subscribe to PubSub from FgHttp application
    {PubSub.subscribe(:fg_http_pub_sub, "config"), config}
  end

  @impl true
  def handle_info({:add_device, caller_pid}, config) do
    {_server_privkey, server_pubkey} = read_privkey()
    {privkey, pubkey} = CLI.genkey()
    new_peers = [pubkey | config[:peers]]
    new_config = %{config | peers: new_peers}
    write!(new_config)

    PubSub.broadcast(
      :fg_http_pub_sub,
      "view",
      {:peer_added, caller_pid, privkey, pubkey, server_pubkey}
    )

    {:noreply, new_config}
  end

  @impl true
  def handle_info({:remove_device, pubkey}, config) do
    new_peers = List.delete(config[:peers], pubkey)
    new_config = %{config | peers: new_peers}
    write!(new_config)
    {:noreply, new_config}
  end

  @doc """
  Writes configuration file.
  """
  def write!(config) do
    Application.get_env(:fg_vpn, :wireguard_conf_path)
    |> File.write!(render(config))
  end

  @doc """
  Reads PrivateKey from configuration file

  Returns a {privkey, pubkey} tuple
  """
  def read_privkey do
    read_config_file()
    |> extract_privkey()
    |> (&{&1, CLI.pubkey(&1)}).()
  end

  defp extract_privkey(config_str) do
    ~r/PrivateKey = (.*)/
    |> Regex.scan(config_str || "")
    |> List.flatten()
    |> List.last()
  end

  @doc """
  Reads configuration file and generates a list of pubkeys
  """
  def read_peers do
    read_config_file()
    |> extract_pubkeys()
  end

  @doc """
  Extracts pubkeys from a configuration file snippet
  """
  def extract_pubkeys(config_str) do
    case config_str do
      nil ->
        nil

      _ ->
        ~r/PublicKey = (.*)/
        |> Regex.scan(config_str)
        |> Enum.map(fn match_list -> List.last(match_list) end)
    end
  end

  @doc """
  Renders WireGuard config in a deterministic way.
  """
  def render(config) do
    @config_header <> interface_to_config(config) <> peers_to_config(config)
  end

  defp listen_port do
    Application.get_env(:fg_http, :vpn_endpoint)
    |> String.split(":")
    |> List.last()
  end

  defp interface_to_config(config) do
    ~s"""
    [Interface]
    ListenPort = #{listen_port()}
    PrivateKey = #{config[:privkey]}
    PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o #{
      config[:default_int]
    } -j MASQUERADE
    PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o #{
      config[:default_int]
    } -j MASQUERADE

    """
  end

  defp read_config_file do
    path = Application.get_env(:fg_vpn, :wireguard_conf_path)

    case File.read(path) do
      {:ok, str} ->
        str

      {:error, reason} ->
        IO.puts(:stderr, "Could not read config: #{reason}")
        nil
    end
  end

  defp peers_to_config(config) do
    Enum.map_join(config[:peers], fn pubkey ->
      ~s"""
      # BEGIN PEER #{pubkey}
      [Peer]
      PublicKey = #{pubkey}
      AllowedIPs = 0.0.0.0/0, ::/0
      # END PEER #{pubkey}
      """
    end)
  end

  defp get_server_keys do
    {privkey, pubkey} = read_privkey()

    if is_nil(privkey) do
      CLI.genkey()
    else
      {privkey, pubkey}
    end
  end

  defp read_and_rewrite_config do
    {privkey, _pubkey} = get_server_keys()

    config = %{
      default_int: CLI.default_interface(),
      privkey: privkey,
      peers: read_peers() || []
    }

    write!(config)

    config
  end
end
