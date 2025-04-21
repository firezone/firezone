defmodule Domain.Events.Event do
  alias Domain.Events.Decoder
  alias Domain.Events.Hooks

  require Logger

  @doc """
  Ingests a WAL write message from Postgres, transforms it into an event, and sends
  it to the appropriate hook module for processing.
  """
  def ingest(msg, relations) do
    {op, tuple_data, old_tuple_data} = extract_msg_data(msg)
    {:ok, relation} = Map.fetch(relations, msg.relation_id)

    table = relation.name
    old_data = zip(old_tuple_data, relation.columns)
    data = zip(tuple_data, relation.columns)

    process(op, table, old_data, data)
  end

  ############
  # accounts #
  ############

  defp process(:insert, "accounts", _old_data, data) do
    Hooks.Accounts.insert(data)
  end

  defp process(:update, "accounts", old_data, data) do
    Hooks.Accounts.update(old_data, data)
  end

  defp process(:delete, "accounts", old_data, _data) do
    Hooks.Accounts.delete(old_data)
  end

  ###########################
  # actor_group_memberships #
  ###########################

  defp process(:insert, "actor_group_memberships", _old_data, data) do
    Hooks.ActorGroupMemberships.insert(data)
  end

  defp process(:update, "actor_group_memberships", old_data, data) do
    Hooks.ActorGroupMemberships.update(old_data, data)
  end

  defp process(:delete, "actor_group_memberships", old_data, _data) do
    Hooks.ActorGroupMemberships.delete(old_data)
  end

  ################
  # actor_groups #
  ################

  defp process(:insert, "actor_groups", _old_data, data) do
    Hooks.ActorGroups.insert(data)
  end

  defp process(:update, "actor_groups", old_data, data) do
    Hooks.ActorGroups.update(old_data, data)
  end

  defp process(:delete, "actor_groups", old_data, _data) do
    Hooks.ActorGroups.delete(old_data)
  end

  ##########
  # actors #
  ##########

  defp process(:insert, "actors", _old_data, data) do
    Hooks.Actors.insert(data)
  end

  defp process(:update, "actors", old_data, data) do
    Hooks.Actors.update(old_data, data)
  end

  defp process(:delete, "actors", old_data, _data) do
    Hooks.Actors.delete(old_data)
  end

  ###################
  # auth_identities #
  ###################

  defp process(:insert, "auth_identities", _old_data, data) do
    Hooks.AuthIdentities.insert(data)
  end

  defp process(:update, "auth_identities", old_data, data) do
    Hooks.AuthIdentities.update(old_data, data)
  end

  defp process(:delete, "auth_identities", old_data, _data) do
    Hooks.AuthIdentities.delete(old_data)
  end

  ##################
  # auth_providers #
  ##################

  defp process(:insert, "auth_providers", _old_data, data) do
    Hooks.AuthProviders.insert(data)
  end

  defp process(:update, "auth_providers", old_data, data) do
    Hooks.AuthProviders.update(old_data, data)
  end

  defp process(:delete, "auth_providers", old_data, _data) do
    Hooks.AuthProviders.delete(old_data)
  end

  ###########
  # clients #
  ###########

  defp process(:insert, "clients", _old_data, data) do
    Hooks.Clients.insert(data)
  end

  defp process(:update, "clients", old_data, data) do
    Hooks.Clients.update(old_data, data)
  end

  defp process(:delete, "clients", old_data, _data) do
    Hooks.Clients.delete(old_data)
  end

  ###################
  # flow_activities #
  ###################

  defp process(:insert, "flow_activities", _old_data, data) do
    Hooks.FlowActivities.insert(data)
  end

  defp process(:update, "flow_activities", old_data, data) do
    Hooks.FlowActivities.update(old_data, data)
  end

  defp process(:delete, "flow_activities", old_data, _data) do
    Hooks.FlowActivities.delete(old_data)
  end

  #########
  # flows #
  #########

  defp process(:insert, "flows", _old_data, data) do
    Hooks.Flows.insert(data)
  end

  defp process(:update, "flows", old_data, data) do
    Hooks.Flows.update(old_data, data)
  end

  defp process(:delete, "flows", old_data, _data) do
    Hooks.Flows.delete(old_data)
  end

  ##################
  # gateway_groups #
  ##################

  defp process(:insert, "gateway_groups", _old_data, data) do
    Hooks.GatewayGroups.insert(data)
  end

  defp process(:update, "gateway_groups", old_data, data) do
    Hooks.GatewayGroups.update(old_data, data)
  end

  defp process(:delete, "gateway_groups", old_data, _data) do
    Hooks.GatewayGroups.delete(old_data)
  end

  ############
  # gateways #
  ############

  defp process(:insert, "gateways", _old_data, data) do
    Hooks.Gateways.insert(data)
  end

  defp process(:update, "gateways", old_data, data) do
    Hooks.Gateways.update(old_data, data)
  end

  defp process(:delete, "gateways", old_data, _data) do
    Hooks.Gateways.delete(old_data)
  end

  ############
  # policies #
  ############

  defp process(:insert, "policies", _old_data, data) do
    Hooks.Policies.insert(data)
  end

  defp process(:update, "policies", old_data, data) do
    Hooks.Policies.update(old_data, data)
  end

  defp process(:delete, "policies", old_data, _data) do
    Hooks.Policies.delete(old_data)
  end

  ################
  # relay_groups #
  ################

  defp process(:insert, "relay_groups", _old_data, data) do
    Hooks.RelayGroups.insert(data)
  end

  defp process(:update, "relay_groups", old_data, data) do
    Hooks.RelayGroups.update(old_data, data)
  end

  defp process(:delete, "relay_groups", old_data, _data) do
    Hooks.RelayGroups.delete(old_data)
  end

  ##########
  # relays #
  ##########

  defp process(:insert, "relays", _old_data, data) do
    Hooks.Relays.insert(data)
  end

  defp process(:update, "relays", old_data, data) do
    Hooks.Relays.update(old_data, data)
  end

  defp process(:delete, "relays", old_data, _data) do
    Hooks.Relays.delete(old_data)
  end

  ########################
  # resource_connections #
  ########################

  defp process(:insert, "resource_connections", _old_data, data) do
    Hooks.ResourceConnections.insert(data)
  end

  defp process(:update, "resource_connections", old_data, data) do
    Hooks.ResourceConnections.update(old_data, data)
  end

  defp process(:delete, "resource_connections", old_data, _data) do
    Hooks.ResourceConnections.delete(old_data)
  end

  #############
  # resources #
  #############

  defp process(:insert, "resources", _old_data, data) do
    Hooks.Resources.insert(data)
  end

  defp process(:update, "resources", old_data, data) do
    Hooks.Resources.update(old_data, data)
  end

  defp process(:delete, "resources", old_data, _data) do
    Hooks.Resources.delete(old_data)
  end

  ##########
  # tokens #
  ##########

  defp process(:insert, "tokens", _old_data, data) do
    Hooks.Tokens.insert(data)
  end

  defp process(:update, "tokens", old_data, data) do
    Hooks.Tokens.update(old_data, data)
  end

  defp process(:delete, "tokens", old_data, _data) do
    Hooks.Tokens.delete(old_data)
  end

  #############
  # CATCH-ALL #
  #############

  defp process(op, table, _old_data, _data) do
    Logger.warning("Unhandled event type!", op: op, table: table)

    :ok
  end

  defp extract_msg_data(%Decoder.Messages.Insert{tuple_data: data}) do
    {:insert, nil, data}
  end

  defp extract_msg_data(%Decoder.Messages.Update{old_tuple_data: data, tuple_data: old}) do
    {:update, old, data}
  end

  defp extract_msg_data(%Decoder.Messages.Delete{old_tuple_data: old}) do
    {:delete, old, nil}
  end

  defp zip(nil, _), do: nil

  defp zip(tuple_data, columns) do
    tuple_data
    |> Tuple.to_list()
    |> Enum.zip(columns)
    |> Map.new(fn {value, column} -> {column.name, value} end)
    |> Enum.into(%{})
  end
end
