defmodule Domain.Auth.Adapters.GoogleWorkspace.APIClient do
  @moduledoc """
  Warning: DO NOT use `fields` parameter with Google API's,
  or they will not return you pagination cursor 🫠.
  """
  use Supervisor

  @pool_name __MODULE__.Finch

  @max_results 350

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Finch,
       name: @pool_name,
       pools: %{
         default: pool_opts()
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool_opts do
    transport_opts =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:finch_transport_opts)

    [conn_opts: [transport_opts: transport_opts]]
  end

  # curl -d 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJodHRwczovL29hdXRoMi5nb29nbGVhcGlzLmNvbS90b2tlbiIsImV4cCI6MTcyNDE5NTQ5MCwiaWF0IjoxNzI0MTkxODkwLCJpc3MiOiJmaXJlem9uZS1pZHAtc3luY0BvcGVuaWQtY29ubmVjdC10ZXN0LTM5MTcxOS5pYW0uZ3NlcnZpY2VhY2NvdW50LmNvbSIsInNjb3BlIjoib3BlbmlkIGVtYWlsIHByb2ZpbGUgaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20vYXV0aC9hZG1pbi5kaXJlY3RvcnkuY3VzdG9tZXIucmVhZG9ubHkgaHR0cHM6Ly93d3cuZ29vZ2xlYXBpcy5jb20vYXV0aC9hZG1pbi5kaXJlY3Rvcnkub3JndW5pdC5yZWFkb25seSBodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL2FkbWluLmRpcmVjdG9yeS5ncm91cC5yZWFkb25seSBodHRwczovL3d3dy5nb29nbGVhcGlzLmNvbS9hdXRoL2FkbWluLmRpcmVjdG9yeS51c2VyLnJlYWRvbmx5In0.hFZl772n74blSgJ2dsZiLKr72tZsDFazuLQ4dVEWBGeR-EEtrhkCA5D7FFuKSWQiW9fbu63LQlO-YiqICSuZv0BGkVzzfZ2Gs96PbGf5ezagq3SJA8H_pbo95Mmd2J_cLwn97NmlfXaksdSQgGdhGi_NtUFRavR_A7idvZWQIQyyt96l5eZULU1QeEm61zx6QFHvx8HiuYYqWurBbeg9_quiSsHJ2yXWRCAg98bEBu0swCV68uBzjkaQuAE-zCqnoDQdfVZCf4-11qoTs-_mgUURW86JhGAWjSKbrDCtHteprUgYRuhpxRsOt4TeK0cbIQFTP1eHxNOmOGfupM34fQ' https://oauth2.googleapis.com/token
  def fetch_service_account_token(jwt) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:token_endpoint)

    token_endpoint = Path.join(endpoint, "token")

    payload =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    request =
      Finch.build(
        :post,
        token_endpoint,
        [{"Content-Type", "application/x-www-form-urlencoded"}],
        payload
      )

    with {:ok, %Finch.Response{body: response, status: status}} when status in 200..299 <-
           Finch.request(request, @pool_name),
         {:ok, %{"access_token" => access_token}} <- Jason.decode(response) do
      {:ok, access_token}
    else
      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Finch.Response{body: response, status: status}} ->
        case Jason.decode(response) do
          {:ok, json_response} ->
            {:error, {status, json_response}}

          _error ->
            {:error, {status, response}}
        end

      other ->
        other
    end
  end

  def list_users(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/users")
      |> URI.append_query(
        URI.encode_query(%{
          "customer" => "my_customer",
          "showDeleted" => false,
          "query" => "isSuspended=false isArchived=false",
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "users")
  end

  def list_groups(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/groups")
      |> URI.append_query(
        URI.encode_query(%{
          "customer" => "my_customer",
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "groups")
  end

  # Note: this functions does not return root (`/`) org unit
  def list_organization_units(api_token) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/customer/my_customer/orgunits")
      |> URI.append_query(
        URI.encode_query(%{
          "maxResults" => @max_results
        })
      )

    list_all(uri, api_token, "organizationUnits")
  end

  def list_group_members(api_token, group_id) do
    endpoint =
      Domain.Config.fetch_env!(:domain, __MODULE__)
      |> Keyword.fetch!(:endpoint)

    uri =
      URI.parse("#{endpoint}/admin/directory/v1/groups/#{group_id}/members")
      |> URI.append_query(
        URI.encode_query(%{
          "includeDerivedMembership" => true,
          "maxResults" => @max_results
        })
      )

    with {:ok, members} <- list_all(uri, api_token, "members") do
      members =
        Enum.filter(members, fn member ->
          member["type"] == "USER" and member["status"] == "ACTIVE"
        end)

      {:ok, members}
    end
  end

  defp list_all(uri, api_token, key, acc \\ []) do
    case list(uri, api_token, key) do
      {:ok, list, nil} ->
        {:ok, List.flatten(Enum.reverse([list | acc]))}

      {:ok, list, next_page_token} ->
        uri
        |> URI.append_query(URI.encode_query(%{"pageToken" => next_page_token}))
        |> list_all(api_token, key, [list | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list(uri, api_token, key) do
    request = Finch.build(:get, uri, [{"Authorization", "Bearer #{api_token}"}])

    with {:ok, %Finch.Response{body: response, status: status}} when status in 200..299 <-
           Finch.request(request, @pool_name),
         {:ok, json_response} <- Jason.decode(response),
         {:ok, list} <- Map.fetch(json_response, key) do
      {:ok, list, json_response["nextPageToken"]}
    else
      {:ok, %Finch.Response{status: status}} when status in 500..599 ->
        {:error, :retry_later}

      {:ok, %Finch.Response{body: response, status: status}} ->
        case Jason.decode(response) do
          {:ok, json_response} ->
            {:error, {status, json_response}}

          _error ->
            {:error, {status, response}}
        end

      :error ->
        {:ok, [], nil}

      other ->
        other
    end
  end
end
