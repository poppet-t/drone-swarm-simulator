class_name ProtocolError
extends RefCounted

## Error codes and the error response envelope for the RL TCP bridge
## (protocol v1). Codes are part of the wire contract with the Julia client;
## do not rename.

const MALFORMED_MESSAGE := "MALFORMED_MESSAGE"
const MISSING_FIELD := "MISSING_FIELD"
const PROTOCOL_VERSION_MISMATCH := "PROTOCOL_VERSION_MISMATCH"
const UNKNOWN_COMMAND := "UNKNOWN_COMMAND"
const EXPECTED_HELLO := "EXPECTED_HELLO"
const INVALID_SEED := "INVALID_SEED"
const UNKNOWN_SCENARIO := "UNKNOWN_SCENARIO"
const INVALID_AGENT_COUNT := "INVALID_AGENT_COUNT"
const NO_ACTIVE_EPISODE := "NO_ACTIVE_EPISODE"
const STALE_EPISODE := "STALE_EPISODE"
const EPISODE_ENDED := "EPISODE_ENDED"
const INVALID_ACTION_SHAPE := "INVALID_ACTION_SHAPE"
const INVALID_ACTION_VALUE := "INVALID_ACTION_VALUE"
const OBSERVATION_VERSION_UNSUPPORTED := "OBSERVATION_VERSION_UNSUPPORTED"
const INTERNAL_ERROR := "INTERNAL_ERROR"


## Builds a failure response envelope. request_id is the ID carried by the
## request (null when the request had no valid ID); episode_id is the episode
## the request referred to (or null where not relevant).
static func make(code: String, message: String, request_id: Variant,
		episode_id: Variant) -> Dictionary:
	return {
		"protocol_version": 1,
		"request_id": request_id,
		"ok": false,
		"episode_id": episode_id,
		"result": null,
		"error": {"code": code, "message": message},
	}
