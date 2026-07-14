defmodule Portal.Repo.Migrations.CreateLogSinkFieldTypes do
  use Ecto.Migration

  @objects ~w[before after subject]

  @integers ~w[content_length inner_src_port inner_dst_port outer_src_port outer_dst_port
               rx_packets tx_packets rx_bytes tx_bytes]

  @strings ~w[type log_id timestamp object operation context actor_id api_token_id method
              path request_id user_agent ip ip_region ip_city phase flow_start flow_end
              last_packet device_id role policy_authorization_id policy_id resource_id
              resource_name resource_address actor_email actor_name client_version
              device_os_name device_os_version protocol inner_src_ip inner_dst_ip
              outer_src_ip outer_dst_ip domain]

  def up do
    create table(:log_sink_field_types, primary_key: false) do
      add(:name, :string, null: false, primary_key: true)
      add(:type, :string, null: false)
      add(:inserted_at, :timestamptz, null: false)
    end

    # Seed the current envelope so steady-state delivery never has to write;
    # runtime registration only fires for fields added in future releases.
    values =
      Enum.map_join(
        Enum.map(@objects, &{&1, "object"}) ++
          Enum.map(@integers, &{&1, "integer"}) ++
          Enum.map(@strings, &{&1, "string"}),
        ", ",
        fn {name, type} -> "('#{name}', '#{type}', now())" end
      )

    execute("INSERT INTO log_sink_field_types (name, type, inserted_at) VALUES #{values}")
  end

  def down do
    drop(table(:log_sink_field_types))
  end
end
