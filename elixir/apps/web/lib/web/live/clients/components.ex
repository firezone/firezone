defmodule Web.Clients.Components do
  use Web, :component_library
  import Web.CoreComponents

  def client_os(assigns) do
    ~H"""
    <div class="flex items-center">
      <span class="mr-1 mb-1"><.client_os_icon client={@client} /></span>
      {get_client_os_name_and_version(@client.last_seen_user_agent)}
    </div>
    """
  end

  def client_os_icon(assigns) do
    ~H"""
    <.icon
      name={client_os_icon_name(@client.last_seen_user_agent)}
      title={get_client_os_name_and_version(@client.last_seen_user_agent)}
      class="w-5 h-5"
    />
    """
  end

  def client_os_name_and_version(assigns) do
    ~H"""
    <span>
      {get_client_os_name_and_version(@client.last_seen_user_agent)}
    </span>
    """
  end

  def client_as_icon(assigns) do
    ~H"""
    <.popover placement="right">
      <:target>
        <.client_os_icon client={@client} />
      </:target>
      <:content>
        <div>
          {@client.name}
          <.icon
            :if={not is_nil(@client.verified_at)}
            name="hero-shield-check"
            class="h-2.5 w-2.5 text-neutral-500"
            title="Device attributes of this client are manually verified"
          />
        </div>
        <div>
          <.client_os_name_and_version client={@client} />
        </div>
        <div>
          <span>Last started:</span>
          <.relative_datetime datetime={@client.last_seen_at} popover={false} />
        </div>
        <div>
          <.connection_status schema={@client} />
        </div>
      </:content>
    </.popover>
    """
  end

  def client_os_icon_name("Windows/" <> _), do: "os-windows"
  def client_os_icon_name("Mac OS/" <> _), do: "os-macos"
  def client_os_icon_name("iOS/" <> _), do: "os-ios"
  def client_os_icon_name("Android/" <> _), do: "os-android"
  def client_os_icon_name("Ubuntu/" <> _), do: "os-ubuntu"
  def client_os_icon_name("Debian/" <> _), do: "os-debian"
  def client_os_icon_name("Manjaro/" <> _), do: "os-manjaro"
  def client_os_icon_name("CentOS/" <> _), do: "os-linux"
  def client_os_icon_name("Fedora/" <> _), do: "os-linux"

  def client_os_icon_name(other) do
    if String.contains?(other, "linux") do
      "os-linux"
    else
      "os-other"
    end
  end

  # This is more complex than it needs to be, but
  # connlib can send "Mac OS" (with a space) violating the User-Agent spec
  defp get_client_os_name_and_version(user_agent) do
    String.split(user_agent, " ")
    |> Enum.reduce_while("", fn component, acc ->
      if String.contains?(component, "/") do
        {:halt, "#{acc} #{String.replace(component, "/", " ")}"}
      else
        {:cont, "#{acc} #{component}"}
      end
    end)
  end
end
