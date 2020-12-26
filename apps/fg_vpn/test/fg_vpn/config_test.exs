defmodule FgVpn.ConfigTest do
  use ExUnit.Case, async: true
  alias FgVpn.Config

  @test_privkey "GMqk2P3deotcQqgqJHfLGB1JtU//f1FgX868bfPKSVc="

  @empty """
  """

  @single_peer """
  # BEGIN PEER test-pubkey
  [Peer]
  PublicKey = test-pubkey
  AllowedIPs = 0.0.0.0/0, ::/0
  # END PEER test-pubkey
  """

  @privkey """
  [Interface]
  ListenPort = 51820
  PrivateKey = GMqk2P3deotcQqgqJHfLGB1JtU//f1FgX868bfPKSVc=
  """

  @rendered_privkey "kPCNOTbBoHC/j5daxhMHcZ+PeNr6oaA8qIWcBuFlM0s="

  @rendered_config """
  # This file is being managed by the fireguard systemd service. Any changes
  # will be overwritten eventually.

  [Interface]
  ListenPort = 51820
  PrivateKey = kPCNOTbBoHC/j5daxhMHcZ+PeNr6oaA8qIWcBuFlM0s=
  PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o noop -j MASQUERADE
  PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o noop -j MASQUERADE

  # BEGIN PEER test-pubkey
  [Peer]
  PublicKey = test-pubkey
  AllowedIPs = 0.0.0.0/0, ::/0
  # END PEER test-pubkey
  """

  def write_config(config) do
    Application.get_env(:fg_vpn, :wireguard_conf_path)
    |> File.write!(config)
  end

  describe "state" do
    setup %{stubbed_config: config} do
      write_config(config)
      test_pid = start_supervised!(Config)

      on_exit(fn ->
        Application.get_env(:fg_vpn, :wireguard_conf_path)
        |> File.rm!()
      end)

      %{test_pid: test_pid}
    end

    @tag stubbed_config: @privkey
    test "parses PrivateKey from config file", %{test_pid: test_pid} do
      assert %{
               peers: [],
               default_int: _,
               privkey: @test_privkey
             } = :sys.get_state(test_pid)
    end

    @tag stubbed_config: @single_peer
    test "parses peers from config file", %{test_pid: test_pid} do
      assert %{
               peers: ["test-pubkey"],
               default_int: _,
               privkey: _
             } = :sys.get_state(test_pid)
    end

    @tag stubbed_config: @empty
    test "writes peers to config when device is verified", %{test_pid: test_pid} do
      send(test_pid, {:verify_device, "test-pubkey"})

      # XXX: Avoid sleeping
      Process.sleep(100)

      assert %{
               peers: ["test-pubkey"],
               default_int: _,
               privkey: _
             } = :sys.get_state(test_pid)
    end

    @tag stubbed_config: @single_peer
    test "removes peers from config when device is removed", %{test_pid: test_pid} do
      send(test_pid, {:remove_device, "test-pubkey"})

      # XXX: Avoid sleeping
      Process.sleep(100)

      assert %{
               peers: [],
               default_int: _,
               privkey: _
             } = :sys.get_state(test_pid)
    end
  end

  describe "loading / rendering" do
    test "renders config" do
      assert Config.render(%{
               default_int: "noop",
               privkey: @rendered_privkey,
               peers: ["test-pubkey"]
             }) == @rendered_config
    end
  end
end
