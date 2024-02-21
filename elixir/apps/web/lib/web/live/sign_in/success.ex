defmodule Web.SignIn.Success do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  def mount(params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :redirect_client, 100)
    end

    query_params =
      params
      |> Map.take(~w[fragment state actor_name identity_provider_identifier])
      |> Map.put("account_slug", socket.assigns.account.slug)
      |> Map.put("account_name", socket.assigns.account.name)

    socket = assign(socket, :params, query_params)
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <section>
      <div class="flex flex-col items-center justify-center px-6 py-8 mx-auto lg:py-0">
        <.logo />

        <div class="w-full col-span-6 mx-auto bg-white rounded shadow md:mt-0 sm:max-w-lg xl:p-0">
          <div class="p-6 space-y-4 lg:space-y-6 sm:p-8">
            <h1 class="text-xl text-center leading-tight tracking-tight text-neutral-900 sm:text-2xl">
              <span>
                Sign in successful.
              </span>
            </h1>
            <p class="text-center">You may close this window.</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def handle_info(:redirect_client, socket) do
    {scheme, url} =
      Domain.Config.fetch_env!(:web, :client_handler)
      |> format_redirect_url()

    query = URI.encode_query(socket.assigns.params)

    {:noreply, redirect(socket, external: {scheme, "#{url}?#{query}"})}
  end

  defp format_redirect_url(raw_client_handler) do
    uri = URI.parse(raw_client_handler)

    maybe_host = if uri.host == "", do: "", else: "#{uri.host}:#{uri.port}/"

    {uri.scheme, "//#{maybe_host}handle_client_sign_in_callback"}
  end
end
