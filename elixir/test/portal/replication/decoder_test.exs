defmodule Portal.Replication.DecoderTest do
  use ExUnit.Case, async: true

  alias Portal.Replication.Decoder
  alias Portal.Replication.Decoder.Messages

  @lsn_binary <<0::integer-32, 23_785_280::integer-32>>
  @lsn_decoded {0, 23_785_280}

  @timestamp_int 704_521_200_000
  @timestamp_decoded ~U[2000-01-09 03:42:01.200000Z]

  @xid 1234
  @relation_id 16384

  # Example OIDs for testing RELATION decoding
  @oid_int4 23
  @oid_text 25
  @oid_numeric 1700
  @oid_unknown 9999

  describe "decode_message/1" do
    test "decodes BEGIN message" do
      # Construct binary message: 'B', final_lsn, commit_timestamp, xid
      message = <<"B", @lsn_binary::binary, @timestamp_int::integer-64, @xid::integer-32>>

      expected = %Messages.Begin{
        final_lsn: @lsn_decoded,
        commit_timestamp: @timestamp_decoded,
        xid: @xid
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes COMMIT message" do
      # Construct binary message: 'C', flags (ignored), lsn, end_lsn, commit_timestamp
      # Flags are currently ignored, represented as []
      flags = <<0::integer-8>>
      end_lsn_binary = <<0::integer-32, 23_785_300::integer-32>>
      end_lsn_decoded = {0, 23_785_300}

      message =
        <<"C", flags::binary-1, @lsn_binary::binary, end_lsn_binary::binary,
          @timestamp_int::integer-64>>

      expected = %Messages.Commit{
        flags: [],
        lsn: @lsn_decoded,
        end_lsn: end_lsn_decoded,
        commit_timestamp: @timestamp_decoded
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes ORIGIN message" do
      # Construct binary message: 'O', origin_commit_lsn, name (null-terminated)
      origin_name = "origin_node_1\0"
      message = <<"O", @lsn_binary::binary, origin_name::binary>>

      expected = %Messages.Origin{
        origin_commit_lsn: @lsn_decoded,
        # The decoder currently includes the null terminator from the split
        name: "origin_node_1\0"
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes RELATION message with known types" do
      # Construct binary message: 'R', id, namespace\0, name\0, replica_identity, num_columns, columns_data
      namespace = "public\0"
      name = "users\0"
      # full
      replica_identity = "f"
      num_columns = 3
      # Column 1: flags=1 (key), name="id", type=23 (int4), modifier=-1
      # Column 2: flags=0, name="email", type=25 (text), modifier=-1
      # Column 3: flags=0, name="balance", type=1700 (numeric), modifier=131076 (e.g., NUMERIC(10,2))
      col1_flags = <<1::integer-8>>
      col1_name = "id\0"
      col1_type = <<@oid_int4::integer-32>>
      col1_mod = <<-1::integer-32>>
      col2_flags = <<0::integer-8>>
      col2_name = "email\0"
      col2_type = <<@oid_text::integer-32>>
      col2_mod = <<-1::integer-32>>
      col3_flags = <<0::integer-8>>
      col3_name = "balance\0"
      col3_type = <<@oid_numeric::integer-32>>
      col3_mod = <<131_076::integer-32>>

      columns_binary =
        <<col1_flags::binary-1, col1_name::binary, col1_type::binary-4, col1_mod::binary-4,
          col2_flags::binary-1, col2_name::binary, col2_type::binary-4, col2_mod::binary-4,
          col3_flags::binary-1, col3_name::binary, col3_type::binary-4, col3_mod::binary-4>>

      message =
        <<"R", @relation_id::integer-32, namespace::binary, name::binary,
          replica_identity::binary-1, num_columns::integer-16, columns_binary::binary>>

      # Expect the string names returned by the actual OidDatabase.name_for_type_id
      expected = %Messages.Relation{
        id: @relation_id,
        namespace: "public",
        name: "users",
        # 'f' maps to :all_columns
        replica_identity: :all_columns,
        columns: [
          %Messages.Relation.Column{
            flags: [:key],
            name: "id",
            # OidDatabase.name_for_type_id(23)
            type: "int4",
            type_modifier: 4_294_967_295
          },
          %Messages.Relation.Column{
            flags: [],
            name: "email",
            # OidDatabase.name_for_type_id(25)
            type: "text",
            type_modifier: 4_294_967_295
          },
          %Messages.Relation.Column{
            flags: [],
            name: "balance",
            # OidDatabase.name_for_type_id(1700)
            type: "numeric",
            type_modifier: 131_076
          }
        ]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes RELATION message with unknown type" do
      # Construct binary message with an OID not listed in OidDatabase
      namespace = "custom_schema\0"
      name = "gadgets\0"
      # index
      replica_identity = "i"
      num_columns = 1
      # Column 1: flags=0, name="widget_type", type=9999 (unknown), modifier=-1
      col1_flags = <<0::integer-8>>
      col1_name = "widget_type\0"
      col1_type = <<@oid_unknown::integer-32>>
      col1_mod = <<-1::integer-32>>

      columns_binary =
        <<col1_flags::binary-1, col1_name::binary, col1_type::binary-4, col1_mod::binary-4>>

      message =
        <<"R", @relation_id::integer-32, namespace::binary, name::binary,
          replica_identity::binary-1, num_columns::integer-16, columns_binary::binary>>

      # Expect the raw OID itself, as per the fallback case in OidDatabase.name_for_type_id
      expected = %Messages.Relation{
        id: @relation_id,
        namespace: "custom_schema",
        name: "gadgets",
        # 'i' maps to :index
        replica_identity: :index,
        columns: [
          %Messages.Relation.Column{
            flags: [],
            name: "widget_type",
            # OidDatabase.name_for_type_id(9999) returns 9999
            type: @oid_unknown,
            type_modifier: 4_294_967_295
          }
        ]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes INSERT message" do
      # Construct binary message: 'I', relation_id, 'N', num_columns, tuple_data
      num_columns = 3
      # Tuple data: 't', len1, val1, 'n', 't', len2, val2
      val1 = "hello world"
      len1 = byte_size(val1)
      val2 = "test"
      len2 = byte_size(val2)

      tuple_data_binary =
        <<"t", len1::integer-32, val1::binary, "n", "t", len2::integer-32, val2::binary>>

      message =
        <<"I", @relation_id::integer-32, "N", num_columns::integer-16, tuple_data_binary::binary>>

      expected = %Messages.Insert{
        relation_id: @relation_id,
        tuple_data: {val1, nil, val2}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes INSERT message with unchanged toast" do
      # Construct binary message: 'I', relation_id, 'N', num_columns, tuple_data
      num_columns = 1
      # Tuple data: 'u'
      tuple_data_binary = <<"u">>

      message =
        <<"I", @relation_id::integer-32, "N", num_columns::integer-16, tuple_data_binary::binary>>

      expected = %Messages.Insert{
        relation_id: @relation_id,
        tuple_data: {:unchanged_toast}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes UPDATE message (simple - New tuple only)" do
      # Construct binary message: 'U', relation_id, 'N', num_columns, tuple_data
      num_columns = 1
      val1 = "new value"
      len1 = byte_size(val1)
      tuple_data_binary = <<"t", len1::integer-32, val1::binary>>

      message =
        <<"U", @relation_id::integer-32, "N", num_columns::integer-16, tuple_data_binary::binary>>

      expected = %Messages.Update{
        relation_id: @relation_id,
        # Default value when not present
        changed_key_tuple_data: nil,
        # Default value when not present
        old_tuple_data: nil,
        tuple_data: {val1}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes UPDATE message (with Old tuple)" do
      # Construct binary message: 'U', relation_id, 'O', num_old_cols, old_tuple_data, 'N', num_new_cols, new_tuple_data
      num_old_cols = 2
      old_val1 = "old value"
      old_len1 = byte_size(old_val1)
      # Old Tuple: text, null
      old_tuple_binary = <<"t", old_len1::integer-32, old_val1::binary, "n">>

      num_new_cols = 2
      new_val1 = "new value"
      new_len1 = byte_size(new_val1)
      new_val2 = "another new"
      new_len2 = byte_size(new_val2)
      # New Tuple: text, text
      new_tuple_binary =
        <<"t", new_len1::integer-32, new_val1::binary, "t", new_len2::integer-32,
          new_val2::binary>>

      message =
        <<"U", @relation_id::integer-32, "O", num_old_cols::integer-16, old_tuple_binary::binary,
          "N", num_new_cols::integer-16, new_tuple_binary::binary>>

      expected = %Messages.Update{
        relation_id: @relation_id,
        changed_key_tuple_data: nil,
        old_tuple_data: {old_val1, nil},
        tuple_data: {new_val1, new_val2}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes UPDATE message (with Key tuple)" do
      # Construct binary message: 'U', relation_id, 'K', num_key_cols, key_tuple_data, 'N', num_new_cols, new_tuple_data
      num_key_cols = 1
      key_val = "key value"
      key_len = byte_size(key_val)
      key_tuple_binary = <<"t", key_len::integer-32, key_val::binary>>

      num_new_cols = 2
      new_val1 = "new value 1"
      new_len1 = byte_size(new_val1)
      # New Tuple: text, unchanged_toast
      new_tuple_binary = <<"t", new_len1::integer-32, new_val1::binary, "u">>

      message =
        <<"U", @relation_id::integer-32, "K", num_key_cols::integer-16, key_tuple_binary::binary,
          "N", num_new_cols::integer-16, new_tuple_binary::binary>>

      expected = %Messages.Update{
        relation_id: @relation_id,
        changed_key_tuple_data: {key_val},
        old_tuple_data: nil,
        tuple_data: {new_val1, :unchanged_toast}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes DELETE message (with Old tuple)" do
      # Construct binary message: 'D', relation_id, 'O', num_columns, tuple_data
      num_columns = 2
      val1 = "deleted value"
      len1 = byte_size(val1)
      # Data: text value, null
      tuple_data_binary = <<"t", len1::integer-32, val1::binary, "n">>

      message =
        <<"D", @relation_id::integer-32, "O", num_columns::integer-16, tuple_data_binary::binary>>

      expected = %Messages.Delete{
        relation_id: @relation_id,
        # Default value
        changed_key_tuple_data: nil,
        old_tuple_data: {val1, nil}
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes DELETE message (with Key tuple)" do
      # Construct binary message: 'D', relation_id, 'K', num_columns, tuple_data
      num_columns = 1
      val1 = "key value"
      len1 = byte_size(val1)
      tuple_data_binary = <<"t", len1::integer-32, val1::binary>>

      message =
        <<"D", @relation_id::integer-32, "K", num_columns::integer-16, tuple_data_binary::binary>>

      expected = %Messages.Delete{
        relation_id: @relation_id,
        changed_key_tuple_data: {val1},
        # Default value
        old_tuple_data: nil
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes TRUNCATE message with no options" do
      # Construct binary message: 'T', num_relations, options, relation_ids
      num_relations = 2
      # No options
      options = 0
      rel_id1 = <<16384::integer-32>>
      rel_id2 = <<16385::integer-32>>
      relation_ids_binary = <<rel_id1::binary-4, rel_id2::binary-4>>

      message =
        <<"T", num_relations::integer-32, options::integer-8, relation_ids_binary::binary>>

      expected = %Messages.Truncate{
        number_of_relations: num_relations,
        # Empty list for 0
        options: [],
        truncated_relations: [16384, 16385]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes TRUNCATE message with CASCADE option" do
      # Construct binary message: 'T', num_relations, options, relation_ids
      num_relations = 1
      # CASCADE
      options = 1
      rel_id1 = <<16384::integer-32>>
      relation_ids_binary = <<rel_id1::binary-4>>

      message =
        <<"T", num_relations::integer-32, options::integer-8, relation_ids_binary::binary>>

      expected = %Messages.Truncate{
        number_of_relations: num_relations,
        options: [:cascade],
        truncated_relations: [16384]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes TRUNCATE message with RESTART IDENTITY option" do
      # Construct binary message: 'T', num_relations, options, relation_ids
      num_relations = 1
      # RESTART IDENTITY
      options = 2
      rel_id1 = <<16384::integer-32>>
      relation_ids_binary = <<rel_id1::binary-4>>

      message =
        <<"T", num_relations::integer-32, options::integer-8, relation_ids_binary::binary>>

      expected = %Messages.Truncate{
        number_of_relations: num_relations,
        options: [:restart_identity],
        truncated_relations: [16384]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes TRUNCATE message with CASCADE and RESTART IDENTITY options" do
      # Construct binary message: 'T', num_relations, options, relation_ids
      num_relations = 3
      # CASCADE | RESTART IDENTITY
      options = 3
      rel_id1 = <<100::integer-32>>
      rel_id2 = <<200::integer-32>>
      rel_id3 = <<300::integer-32>>
      relation_ids_binary = <<rel_id1::binary-4, rel_id2::binary-4, rel_id3::binary-4>>

      message =
        <<"T", num_relations::integer-32, options::integer-8, relation_ids_binary::binary>>

      expected = %Messages.Truncate{
        number_of_relations: num_relations,
        options: [:cascade, :restart_identity],
        truncated_relations: [100, 200, 300]
      }

      assert Decoder.decode_message(message) == expected
    end

    test "decodes TYPE message" do
      # Construct binary message: 'Y', data_type_id, namespace\0, name\0
      # Example OID for varchar
      type_id = 1043
      namespace = "pg_catalog\0"
      name = "varchar\0"

      message = <<"Y", type_id::integer-32, namespace::binary, name::binary>>

      expected = %Messages.Type{
        id: type_id,
        namespace: "pg_catalog",
        name: "varchar"
      }

      assert Decoder.decode_message(message) == expected
    end

    test "handles unsupported message type" do
      # Use an arbitrary starting byte not handled ('X')
      message = <<"X", 1, 2, 3, 4>>

      expected = %Messages.Unsupported{
        data: message
      }

      assert Decoder.decode_message(message) == expected
    end

    test "handles empty binary message" do
      message = <<>>
      expected = %Messages.Unsupported{data: <<>>}
      assert Decoder.decode_message(message) == expected
    end

    test "handles message with only type byte" do
      message = <<"B">>

      expected = %Messages.Unsupported{
        data: "B"
      }

      assert Decoder.decode_message(message) == expected
    end
  end
end
