defmodule Web.Sites.Components do
  use Web, :component_library

  def pretty_print_routing(routing) do
    case routing do
      :managed -> "Firezone Managed Relays"
      :self_hosted -> "Self Hosted Relays"
      :stun_only -> "Direct Only"
      routing -> to_string(routing)
    end
  end
end
