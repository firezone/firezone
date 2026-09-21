defmodule PortalWeb.ResourceTypeComponents do
  @moduledoc """
  How a resource's type is labelled and badged.

  Lives here rather than in `PortalWeb.Resources.Components` because the policies, sites and
  groups views all render resource-type badges, and `Resources.Components` already imports
  `Policies.Components` — so `Policies.Components` cannot import it back without a compile
  cycle. This module imports nothing, so every view can reach it.

  Imported globally via `PortalWeb.components/0`; no explicit import is needed.
  """

  @base "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase"

  @doc """
  Human-readable label for a resource type.

  The badge renders it uppercased in CSS, so `:device_pool` must not reach the markup as a raw
  atom — it would show as `DEVICE_POOL` rather than `DEVICE POOL`.
  """
  @spec resource_type_label(atom()) :: String.t()
  def resource_type_label(:dns), do: "DNS"
  def resource_type_label(:ip), do: "IP"
  def resource_type_label(:cidr), do: "CIDR"
  def resource_type_label(:internet), do: "Internet"
  def resource_type_label(:device_pool), do: "Device Pool"
  def resource_type_label(type), do: to_string(type)

  @doc """
  Classes for a resource-type badge.

  Every type needs its own clause: an unmatched type falls through to the neutral catch-all and
  renders gray, which reads as a missing style rather than a deliberate one.
  """
  @spec type_badge_class(atom()) :: String.t()
  def type_badge_class(:dns), do: @base <> " bg-badge-dns text-badge-dns-text"
  def type_badge_class(:ip), do: @base <> " bg-badge-ip text-badge-ip-text"
  def type_badge_class(:cidr), do: @base <> " bg-badge-cidr text-badge-cidr-text"

  def type_badge_class(:internet),
    do: @base <> " bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  def type_badge_class(:device_pool),
    do: @base <> " bg-badge-device-pool text-badge-device-pool-text"

  def type_badge_class(_), do: @base <> " bg-raised text-body"

  @doc """
  Width class reserving room for the widest badge among `types`.

  Lets the names beside the badges line up, without the cost of a single fixed width: that
  either clips the longest label ("Device Pool" needs ~84px) or strands the shortest ("IP" needs
  ~26px) far from its name. Sizing to the widest label *present* keeps short-only lists tight
  and mixed lists aligned.
  """
  @spec type_badge_col_class([atom()]) :: String.t()
  def type_badge_col_class(types) do
    widest =
      types
      |> Enum.map(&String.length(resource_type_label(&1)))
      |> Enum.max(fn -> 0 end)

    cond do
      widest <= 4 -> "w-14"
      widest <= 8 -> "w-20"
      true -> "w-24"
    end
  end
end
