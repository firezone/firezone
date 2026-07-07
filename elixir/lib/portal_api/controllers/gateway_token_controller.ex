defmodule PortalAPI.GatewayTokenController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias Portal.Authentication
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Gateway Tokens"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Create a Gateway Token",
    description:
      "Deprecated: creates a multi-owner Site token shared by all of a Site's " <>
        "gateways. Prefer creating a single-owner token for a specific gateway " <>
        "via `POST /sites/{site_id}/gateways/{gateway_id}/token`.",
    deprecated: true,
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [
        created: {"New Token Response", "application/json", PortalAPI.Schemas.GatewayToken.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {:ok, token} <- Authentication.create_gateway_token(site, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Authentication.encode_fragment!(token))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create_for_gateway,
    summary: "Create a single-owner Gateway Token",
    description:
      "Creates a token bound to a single gateway. At most one active token can " <>
        "exist per gateway; if one already exists, this returns 409 Conflict - " <>
        "rotate the token or delete it first instead.",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      gateway_id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [
        created: {"New Token Response", "application/json", PortalAPI.Schemas.GatewayToken.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :conflict,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create_for_gateway(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_for_gateway(conn, %{"gateway_id" => gateway_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Database.fetch_gateway(gateway_id, subject),
         {:ok, token} <- Authentication.create_gateway_token(gateway, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Authentication.encode_fragment!(token))
    else
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if unique_violation?(errors) do
          Error.handle(conn, {:error, :conflict, reason: token_exists_message()})
        else
          Error.handle(conn, {:error, changeset})
        end

      error ->
        Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :rotate,
    summary: "Rotate a single-owner Gateway Token",
    description:
      "Mints a replacement token for the gateway. A current token the gateway " <>
        "has connected with keeps working until the gateway first connects " <>
        "with the replacement or " <>
        "#{Portal.GatewayToken.rotation_grace_hours()} hours elapse, whichever " <>
        "comes first; a token no gateway has ever connected with is replaced " <>
        "immediately. Rotating again before the gateway picks up the " <>
        "replacement replaces only the pending token and never invalidates the " <>
        "one in use. Once the replacement is confirmed the previous token is " <>
        "deleted - rolling the gateway's configuration back to it will strand " <>
        "the gateway.",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      gateway_id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [
        created: {"New Token Response", "application/json", PortalAPI.Schemas.GatewayToken.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec rotate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate(conn, %{"gateway_id" => gateway_id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Database.fetch_gateway(gateway_id, subject),
         {:ok, token} <- Authentication.rotate_gateway_token(gateway, subject) do
      conn
      |> put_status(:created)
      |> render(:show, token: token, encoded_token: Authentication.encode_fragment!(token))
    else
      error -> Error.handle(conn, error)
    end
  end

  defp unique_violation?(errors) do
    match?({_msg, opts} when is_list(opts), errors[:device_id]) and
      Keyword.get(elem(errors[:device_id], 1), :constraint) == :unique
  end

  defp token_exists_message do
    "An active token already exists for this gateway. Rotate it or delete it first."
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Delete a Gateway Token",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Token ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [
        ok:
          {"Deleted Token Response", "application/json",
           PortalAPI.Schemas.GatewayToken.DeletedResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"site_id" => _site_id, "id" => token_id}) do
    subject = conn.assigns.subject

    with {:ok, token} <- Database.fetch_token(token_id, subject),
         {:ok, deleted_token} <- Database.delete_token(token, subject) do
      render(conn, :deleted, token: deleted_token)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete_all,
    summary: "Delete all Gateway Tokens for a Site",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [
        ok:
          {"Deleted Tokens Response", "application/json",
           PortalAPI.Schemas.GatewayToken.DeletedAllResponse}
      ] ++
        ProblemDetails.responses([:unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec delete_all(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_all(conn, %{"site_id" => site_id}) do
    subject = conn.assigns.subject

    with {:ok, site} <- Database.fetch_site(site_id, subject),
         {deleted_count, _} <- Database.delete_all_tokens(site, subject) do
      render(conn, :deleted_all, count: deleted_count)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Device
    alias Portal.Safe
    alias Portal.Site
    alias Portal.GatewayToken

    def fetch_gateway(id, subject) do
      result =
        from(d in Device, as: :gateways)
        |> where([gateways: d], d.id == ^id and d.type == :gateway)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end

    def fetch_site(id, subject) do
      result =
        from(s in Site, as: :sites)
        |> where([sites: s], s.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil ->
          {:error, :not_found}

        site ->
          {:ok, site}
      end
    end

    def fetch_token(id, subject) do
      result =
        from(t in GatewayToken, where: t.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        token -> {:ok, token}
      end
    end

    def delete_token(token, subject) do
      token
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def delete_all_tokens(site, subject) do
      from(t in GatewayToken, where: t.site_id == ^site.id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end
end
