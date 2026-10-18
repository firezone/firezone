-- Views over the JSON Lines that `emit-json tunnel-proto` writes; IDs are unique only within an input.
CREATE VIEW inputs AS SELECT * FROM read_json_auto('json/tunnel-proto/inputs.jsonl', sample_size = -1);
CREATE VIEW sites AS SELECT * FROM read_json_auto('json/tunnel-proto/sites.jsonl', sample_size = -1);
CREATE VIEW resources AS SELECT * FROM read_json_auto('json/tunnel-proto/resources.jsonl', sample_size = -1);
CREATE VIEW clients AS SELECT * FROM read_json_auto('json/tunnel-proto/clients.jsonl', sample_size = -1);
CREATE VIEW gateways AS SELECT * FROM read_json_auto('json/tunnel-proto/gateways.jsonl', sample_size = -1);
CREATE VIEW relays AS SELECT * FROM read_json_auto('json/tunnel-proto/relays.jsonl', sample_size = -1);
CREATE VIEW dns_records AS SELECT * FROM read_json_auto('json/tunnel-proto/dns_records.jsonl', sample_size = -1);
CREATE VIEW transitions AS SELECT * FROM read_json_auto('json/tunnel-proto/transitions.jsonl', sample_size = -1);
CREATE VIEW dns_queries AS SELECT * FROM read_json_auto('json/tunnel-proto/dns_queries.jsonl', sample_size = -1);
CREATE VIEW probes AS SELECT * FROM read_json_auto('json/tunnel-proto/probes.jsonl', sample_size = -1);
