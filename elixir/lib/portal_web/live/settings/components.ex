defmodule PortalWeb.Settings.Components do
  use PortalWeb, :component_library

  @doc """
  Pulsing placeholder rows shown where data will appear once it has loaded.

  Pages render it on the static render instead of querying, so the data is
  only loaded once, by the connected mount.

  ## Examples

      <SettingsComponents.skeleton id="providers-skeleton" />
      <SettingsComponents.skeleton id="usage-skeleton" rows={3} class="max-w-2xl" />
  """
  attr :id, :string, required: true
  attr :rows, :integer, default: 4
  attr :class, :any, default: nil

  def skeleton(assigns) do
    ~H"""
    <div id={@id} aria-hidden="true" class={["animate-pulse", @class]}>
      <div
        :for={width <- Enum.take(Stream.cycle(~w[w-48 w-36 w-56 w-40]), @rows)}
        class="border-b border-border px-6 py-4"
      >
        <div class={["h-3 rounded bg-border-strong max-w-full", width]}></div>
        <div class="mt-2 h-2 w-24 rounded bg-border"></div>
      </div>
    </div>
    """
  end
end
