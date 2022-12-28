defmodule FzVpn.ServerTest do
  use ExUnit.Case, async: true

  setup %{stubbed_config: config} do
    test_pid = :global.whereis_name(:fz_vpn_server)
    :ok = GenServer.call(test_pid, {:set_config, config})

    %{test_pid: test_pid}
  end

  describe "state" do
    @pubkey "2Bp11cX3ETPs4/bbKdn44OywJAqD6XuzWG6VCrlSzXI="
    @psk "sGaRdRnjo58qCuNnb4zIwAfZa0mOmD6aDfsxye9Tw3s="
    @key1 "KGIx2Yt8S+dc2886Y9H4lrFzm3Hh7f//Ix0Ip/mdX2k="
    @key2 "MDxx3EkWIBI1KfBhnAdwfdqGcFMKz32+PgIOro4g9Eo="
    @key3 "wMc2ntAv2w233Qsy+VMfFHzF4J4rPaj2+HYeFV99YH8="
    @key4 "wN2yynjMdSzFcVrzfl7v89YOuBfNWhMAklgfeA3PQG0="
    @key5 "8IkpsAXiqhqNdc9PJS76YeJjig4lyTBaf8Rm7gTApXk="

    @single_peer [
      %{public_key: @pubkey, preshared_key: @psk, inet: "127.0.0.1/32,::1/128"}
    ]
    @many_peers [
      %{public_key: @key1, preshared_key: @psk, inet: "0.0.0.0/32,::1/128"},
      %{public_key: @key2, preshared_key: @psk, inet: "127.0.0.1/32,::1/128"},
      %{public_key: @key3, preshared_key: @psk, inet: "127.0.0.1/32,::1/128"},
      %{public_key: @key4, preshared_key: @psk, inet: "127.0.0.1/32,::1/128"}
    ]

    @tag stubbed_config: @single_peer
    test "removes peers from config when removed", %{test_pid: test_pid} do
      GenServer.call(test_pid, {:remove_peer, @pubkey})

      assert :sys.get_state(test_pid) == %{}
    end

    @tag stubbed_config: @many_peers
    test "calcs diff and sets only the diff", %{test_pid: test_pid} do
      new_peers = [%{public_key: @key5, inet: "1.1.1.1/32,::2/128", preshared_key: @psk}]

      assert :sys.get_state(test_pid) == %{
               @key1 => %{allowed_ips: "0.0.0.0/32,::1/128", preshared_key: @psk},
               @key2 => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: @psk},
               @key3 => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: @psk},
               @key4 => %{allowed_ips: "127.0.0.1/32,::1/128", preshared_key: @psk}
             }

      :ok = GenServer.call(test_pid, {:set_config, new_peers})

      assert :sys.get_state(test_pid) == %{
               @key5 => %{allowed_ips: "1.1.1.1/32,::2/128", preshared_key: @psk}
             }
    end
  end
end
