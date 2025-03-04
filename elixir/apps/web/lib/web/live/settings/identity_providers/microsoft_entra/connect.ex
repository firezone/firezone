defmodule Web.Settings.IdentityProviders.MicrosoftEntra.Connect do
  @doc """
  This controller is similar to Web.AuthController, but it is used to connect IdP account
  to the actor and provider rather than logging in using it.
  """
  use Web, :controller
  alias Domain.Auth.Adapters.MicrosoftEntra
  require Logger

  def redirect_to_idp(conn, %{"provider_id" => provider_id}) do
    account = conn.assigns.account

    with {:ok, provider} <- Domain.Auth.fetch_provider_by_id(provider_id, conn.assigns.subject),
         redirect_url =
           url(
             ~p"/#{provider.account_id}/settings/identity_providers/microsoft_entra/#{provider}/handle_callback"
           ),
         {:ok, conn} <-
           Web.AuthController.redirect_to_idp(conn, redirect_url, provider, %{prompt: "consent"}) do
      conn
    else
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Provider does not exist.")
        |> redirect(to: ~p"/#{account}/settings/identity_providers")

      {:error, {status, body}} ->
        Logger.warning("Failed to redirect to IdP", status: status, body: inspect(body))

        conn
        |> put_flash(:error, "Your identity provider returned #{status} HTTP code.")
        |> redirect(to: ~p"/#{account}/settings/identity_providers")

      {:error, %{reason: :timeout}} ->
        Logger.warning("Failed to redirect to IdP", reason: :timeout)

        conn
        |> put_flash(:error, "Your identity provider took too long to respond.")
        |> redirect(to: ~p"/#{account}/settings/identity_providers")

      {:error, reason} ->
        Logger.warning("Failed to redirect to IdP", reason: inspect(reason))

        conn
        |> put_flash(:error, "Your identity provider is not available right now.")
        |> redirect(to: ~p"/#{account}/settings/identity_providers")
    end
  end

  def handle_idp_callback(conn, %{
        "provider_id" => provider_id,
        "state" => state,
        "code" => code
      }) do
    account = conn.assigns.account
    subject = conn.assigns.subject

    with {:ok, _redirect_params, code_verifier, conn} <-
           Web.AuthController.verify_idp_state_and_fetch_verifier(conn, provider_id, state) do
      payload = {
        url(
          ~p"/#{account.id}/settings/identity_providers/microsoft_entra/#{provider_id}/handle_callback"
        ),
        code_verifier,
        code
      }

      with {:ok, provider} <- Domain.Auth.fetch_provider_by_id(provider_id, conn.assigns.subject),
           {:ok, identity} <-
             MicrosoftEntra.verify_and_upsert_identity(subject.actor, provider, payload),
           attrs = %{
             adapter_state: identity.provider_state,
             disabled_at: nil,
             last_syncs_failed: 0,
             last_sync_error: nil,
             sync_disabled_at: nil
           },
           {:ok, _provider} <- Domain.Auth.update_provider(provider, attrs, subject) do
        redirect(conn,
          to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
        )
      else
        {:error, :expired_token} ->
          conn
          |> put_flash(:error, "The provider returned an expired token, please try again.")
          |> redirect(
            to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
          )

        {:error, :invalid_token} ->
          conn
          |> put_flash(:error, "The provider returned an invalid token, please try again.")
          |> redirect(
            to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
          )

        {:error, :not_found} ->
          conn
          |> put_flash(:error, "Provider does not exist.")
          |> redirect(
            to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          errors =
            changeset
            |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
              Regex.replace(~r"%{(\w+)}", message, fn _, key ->
                opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
              end)
            end)
            |> Map.get(:adapter_config, %{})

          conn
          |> put_flash(
            :error,
            {:validation_errors, "There is an error with provider behaviour", errors}
          )
          |> redirect(
            to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
          )

        {:error, _reason} ->
          conn
          |> put_flash(:error, "You may not authenticate to this account.")
          |> redirect(
            to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
          )
      end
    else
      {:error, :invalid_state, conn} ->
        conn
        |> put_flash(:error, "Your session has expired, please try again.")
        |> redirect(
          to: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider_id}"
        )
    end
  end

  def handle_idp_callback(conn, %{"provider_id" => provider_id} = params) do
    Logger.warning("Invalid request parameters", params: params)

    conn
    |> put_flash(:error, "Invalid request parameters: #{inspect(params)}")
    |> redirect(
      to: ~p"/#{conn.assigns.account}/settings/identity_providers/microsoft_entra/#{provider_id}"
    )
  end
end
