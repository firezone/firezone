defmodule FzHttp.Rules do
  alias FzHttp.{Repo, Auth, Validator, Telemetry}
  alias FzHttp.Rules.{Authorizer, Rule}

  def fetch_count_by_user_id(user_id, %Auth.Subject{} = subject) do
    if Validator.valid_uuid?(user_id) do
      queryable =
        Rule.Query.by_user_id(user_id)
        |> Authorizer.for_subject(subject)

      {:ok, Repo.aggregate(queryable, :count)}
    else
      {:ok, 0}
    end
  end

  def fetch_rule_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()),
         true <- Validator.valid_uuid?(id) do
      Rule.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_rule_by_id!(id) do
    Rule.Query.by_id(id)
    |> Repo.one!()
  end

  def list_rules(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()) do
      Rule.Query.all()
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    end
  end

  def list_rules_by_user_id(user_id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()),
         true <- Validator.valid_uuid?(user_id) do
      Rule.Query.by_user_id(user_id)
      |> Authorizer.for_subject(subject)
      |> Repo.list()
    else
      false -> {:ok, []}
      other -> other
    end
  end

  def new_rule(attrs \\ %{}) do
    Rule.Changeset.create_changeset(attrs)
  end

  def change_rule(%Rule{} = rule, attrs \\ %{}) do
    Rule.Changeset.update_changeset(rule, attrs)
  end

  def create_rule(attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()) do
      create_rule(attrs)
    end
  end

  def create_rule(attrs) do
    changeset = Rule.Changeset.create_changeset(attrs)

    with {:ok, rule} <- Repo.insert(changeset) do
      Telemetry.add_rule()
      {:ok, rule}
    end
  end

  def update_rule(%Rule{} = rule, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()) do
      rule
      |> Rule.Changeset.update_changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_rule(%Rule{} = rule, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_rules_permission()) do
      Telemetry.delete_rule()
      Repo.delete(rule)
    end
  end

  def setting_projection(rule_or_map) do
    %{
      destination: to_string(rule_or_map.destination),
      action: rule_or_map.action,
      user_id: rule_or_map.user_id,
      port_type: rule_or_map.port_type,
      port_range: rule_or_map.port_range
    }
  end

  def port_rules_supported?, do: FzHttp.Config.fetch_env!(:fz_wall, :port_based_rules_supported)

  def as_settings do
    port_rules_supported?()
    |> scope()
    |> Repo.all()
    |> Enum.map(&setting_projection/1)
    |> MapSet.new()
  end

  defp scope(true), do: Rule.Query.all()
  defp scope(false), do: Rule.Query.by_empty_port_type()

  def allowlist do
    Rule.Query.by_action(:accept)
    |> Repo.all()
  end

  def denylist do
    Rule.Query.by_action(:drop)
    |> Repo.all()
  end
end
