defmodule Web.SignIn.Success do
  use Web, {:live_view, layout: {Web.Layouts, :public}}

  def mount(params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :redirect_client, 1)
    end

    query_params =
      params
      |> Map.take(
        ~w[fragment state actor_name account_slug account_name identity_provider_identifier]
      )

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
                Sign in successful
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
    client_handler = Domain.Config.fetch_env!(:web, :client_handler)

    query = URI.encode_query(socket.assigns.params)

    {:noreply,
     redirect(socket, external: {client_handler, "//handle_client_sign_in_callback?#{query}"})}
  end
end
