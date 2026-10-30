@tool
extends Node

class_name AiClient

signal response_received(text: String)
signal request_failed(message: String)
signal stream_updated(full_text: String)
signal retry_scheduled(next_attempt: int, total_attempts: int, delay_sec: float)
signal tool_calls_received(calls: Array, preamble: String)

const URL := "https://api.meta.ai/v1/chat/completions" # API Url
const SETTINGS_API_KEY := "plugins/gd_ai/api_key"
const SETTINGS_API_URL := "plugins/gd_ai/api_url"
const SETTINGS_MODEL := "plugins/gd_ai/model"

var api_key := ""
var model := "muse-spark-1.3-contributor"
var reasoning_effort := "minimal"   # "minimal" | "low" | "medium" | "high" | "xhigh" ("none" is rejected)
var system_prompt := ""         # sent as a developer message, never stored in chat history
var max_completion_tokens := 64 #2048
var busy := false
var api_url := URL # override (e.g. via MODEL_API_URL) to test another endpoint without editing code
var streaming := false # when true, send() uses stream:true with chunked SSE append
var stream_timeout := 120.0 # seconds for the whole streamed request
var max_retries := 3 # automatic retries for transient failures (429, 5xx, timeouts, network errors)
var retry_base_delay := 1.0 # seconds; doubles per attempt, plus jitter
var retry_max_delay := 30.0 # seconds; ceiling for backoff (a Retry-After header can extend past it)
var tools: Array = [] # declared editor actions, sent as the tools array (empty = plain chat)
var tool_choice = "auto" # "auto" | "none" | "required", or {"type": "function", "function": {"name": ...}}
var context_prompt := "" # fresh editor snapshot per request; never stored in chat history
var max_context_chars := 4000 # clamp on injected context (<= 0 = unlimited)
var max_history_messages := 20 # cap on history turns sent per request (<= 0 = unlimited)
var max_history_chars := 8000 # cap on history text sent per request (<= 0 = unlimited)

var _http: HTTPRequest
var _stream_client: HTTPClient
var _streaming_active := false
var _stream_request_sent := false
var _stream_status_checked := false
var _stream_code := 0
var _stream_path := ""
var _stream_headers := PackedStringArray()
var _stream_body := ""
var _stream_leftover := ""
var _stream_content := ""
var _stream_error_bytes := PackedByteArray()
var _stream_deadline := 0
var _pending_messages: Array = []
var _retry_attempt := 0
var _request_generation := 0
var _expecting_response := false
var _json_fallback_active := false
var _stream_tool_calls: Dictionary = {}
var _stream_tool_announced := false
var _history_dropped := 0


# Generate a new HTTP request upon instantiation
func _ready() -> void:
	_ensure_http()
	set_process(false) # enabled only while a stream is being polled


# Ensure there is a http request
func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


# Checks if the editor has the API key and returns it
static func _get_editor_setting(settings: EditorSettings, key: String) -> String:
	if settings.has_setting(key):
		return str(settings.get_setting(key))
	return ""


# Loads persisted config, with environment variables overriding when set.
func load_config() -> void:
	var stored_key := ""
	var stored_url := ""
	var stored_model := ""
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		stored_key = _get_editor_setting(settings, SETTINGS_API_KEY)
		stored_url = _get_editor_setting(settings, SETTINGS_API_URL)
		stored_model = _get_editor_setting(settings, SETTINGS_MODEL)
	api_key = stored_key.strip_edges()
	api_url = stored_url.strip_edges()
	if not stored_model.strip_edges().is_empty():
		model = stored_model.strip_edges()
	var env_key := OS.get_environment("MODEL_API_KEY").strip_edges()
	if not env_key.is_empty():
		api_key = env_key
	var env_url := OS.get_environment("MODEL_API_URL").strip_edges()
	if not env_url.is_empty():
		api_url = env_url
	if api_key.is_empty():
		push_warning("[GdAI] No API key configured. Open GdAI Settings or set MODEL_API_KEY.")
		return
	var source := "env" if not env_key.is_empty() else "settings"
	var endpoint := api_url if not api_url.is_empty() else URL
	print("[GdAI] Config loaded: model=%s endpoint=%s key=%s [%s]." % [model, endpoint, fingerprint(api_key), source])


# Persists the current key, endpoint, and model for the next session.
func save_config() -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(SETTINGS_API_KEY, api_key.strip_edges())
	settings.set_setting(SETTINGS_API_URL, api_url.strip_edges())
	settings.set_setting(SETTINGS_MODEL, model.strip_edges())


# Sends a message to ai with adjusted settings
# Throw error if HTTP request could not be started
func send(messages: Array) -> void:
	if busy:
		return
	var key := _sanitize_key(api_key)
	if key.is_empty():
		request_failed.emit("No API key set. Set the MODEL_API_KEY environment variable and fully relaunch the editor (Cmd+Q, not just reopen the project).")
		return
	if _looks_like_placeholder(key):
		request_failed.emit("MODEL_API_KEY looks like a placeholder. Paste the real key and fully relaunch the editor.")
		return
	if key.contains(" ") or key.contains("\t") or key.contains("\n") or key.contains("\r"):
		request_failed.emit("API key contains spaces or line breaks. Re-copy it without quotes or extra characters.")
		return
	var trimmed := trim_history(messages, max_history_messages, max_history_chars)
	_pending_messages = trimmed["messages"]
	_history_dropped = int(trimmed["dropped"])
	if _history_dropped > 0:
		print("[GdAI] Trimmed %d oldest %s to fit the history budget." % [_history_dropped, "message" if _history_dropped == 1 else "messages"])
	_retry_attempt = 0
	_json_fallback_active = false
	_request_generation += 1
	_start_request()


# Start a request to AI
func _start_request() -> void:
	var key := _sanitize_key(api_key) # Sanitize key

	# Handle no API key set
	if key.is_empty():
		busy = false
		_expecting_response = false
		request_failed.emit("No API key set. Set the MODEL_API_KEY environment variable and fully relaunch the editor (Cmd+Q, not just reopen the project).")
		return

	# Handle if already streaming
	if streaming and not _json_fallback_active:
		_send_stream(_pending_messages, key)
		return

	_ensure_http() # Create HTTP response
	if _http == null:
		busy = false
		request_failed.emit("HTTP client is not ready.")
		return

	# Set payload messages
	var payload_messages: Array = []
	var effective_system := _effective_system_prompt()
	if not effective_system.is_empty():
		payload_messages.append({"role": "developer", "content": effective_system})
	var context := _effective_context_prompt()
	if not context.is_empty():
		payload_messages.append({"role": "developer", "content": context})
	if _history_dropped > 0:
		payload_messages.append({"role": "developer", "content": "[History note: %d oldest %s trimmed to fit the budget.]" % [_history_dropped, "message" if _history_dropped == 1 else "messages"]})
	payload_messages.append_array(_pending_messages)

	# Set HTTP headers
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % key,
		"Content-Type: application/json",
	])

	# Create JSON body and fill settings
	var payload := {
		"model": model,
		"messages": payload_messages,
		"reasoning_effort": reasoning_effort,
		"max_completion_tokens": max_completion_tokens,
	}
	_apply_tool_fields(payload)
	var body := JSON.stringify(payload)

	var url := api_url.strip_edges() # Strip URL
	if url.is_empty():
		url = URL

	# Send POST request
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		var start_message := "Could not start request (error %d)." % err

		# Check if can retry
		if _retry_attempt < max_retries:
			_schedule_retry(_backoff_delay(), start_message)
		else:
			request_failed.emit(start_message)
		return
	_expecting_response = true
	busy = true


# Tolerate pasting the whole header value or a quoted string.
static func _sanitize_key(raw: String) -> String:
	var key := raw.strip_edges()
	if key.to_lower().begins_with("bearer "):
		key = key.substr("bearer ".length()).strip_edges()
	if key.length() >= 2 \
			and ((key.begins_with('"') and key.ends_with('"')) \
			or (key.begins_with("'") and key.ends_with("'"))):
		key = key.substr(1, key.length() - 2).strip_edges()
	return key


# Check if API key looks like placeholder
static func _looks_like_placeholder(key: String) -> bool:
	var lowered := key.to_lower()
	if lowered in ["your-key-here", "your_api_key", "your-api-key", "changeme", "xxx", "test", "key", "api_key", "apikey"]:
		return true
	return lowered.begins_with("your-key") or lowered.begins_with("your_key") \
		or lowered.begins_with("paste-") or lowered.begins_with("insert-")


# Masked fingerprint for logs: confirms which key loaded without leaking it.
static func fingerprint(raw: String) -> String:
	var key := _sanitize_key(raw)
	if key.is_empty():
		return "missing"
	if key.length() <= 6:
		return "len=%d (too short to fingerprint safely)" % key.length()
	return "len=%d %s…%s" % [key.length(), key.left(4), key.substr(key.length() - 2)]


# Declared editor actions, in OpenAI tools format. Phase 2 executes these;
# Phase 3 only sends the schema and parses/validates the returned calls.
static func default_tools() -> Array:
	return [
		{
			"type": "function",
			"function": {
				"name": "create_node",
				"description": "Create a new node in the edited scene.",
				"parameters": {
					"type": "object",
					"properties": {
						"node_type": {"type": "string", "description": "Godot class name, e.g. Button, VBoxContainer, Node3D."},
						"name": {"type": "string", "description": "Node name. Defaults to the node type."},
						"parent": {"type": "string", "description": "Path of the parent node. Defaults to the scene root."},
					},
					"required": ["node_type"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": "set_property",
				"description": "Set a property on a node in the edited scene.",
				"parameters": {
					"type": "object",
					"properties": {
						"node": {"type": "string", "description": "Path of the target node."},
						"property": {"type": "string", "description": "Property name, e.g. text, position, visible."},
						"value": {"description": "New value (any JSON type)."},
					},
					"required": ["node", "property", "value"],
					"additionalProperties": false,
				},
			},
		},
		{
			"type": "function",
			"function": {
				"name": "attach_script",
				"description": "Attach a script to a node in the edited scene.",
				"parameters": {
					"type": "object",
					"properties": {
						"node": {"type": "string", "description": "Path of the target node."},
						"script_path": {"type": "string", "description": "Resource path of the script, e.g. res://player.gd."},
					},
					"required": ["node", "script_path"],
					"additionalProperties": false,
				},
			},
		},
	]


# One-line signature for the JSON-mode fallback instruction, built from the schema.
static func _tool_signature(tool_def) -> String:
	if not tool_def is Dictionary:
		return ""
	var fn = tool_def.get("function", {})
	if not fn is Dictionary:
		return ""
	var fname := str(fn.get("name", ""))
	if fname.is_empty():
		return ""
	var properties := {}
	var required: Array = []
	var params = fn.get("parameters", {})
	if params is Dictionary:
		if params.get("properties", {}) is Dictionary:
			properties = params["properties"]
		if params.get("required", []) is Array:
			required = params["required"]
	var parts: Array[String] = []
	for pname in properties.keys():
		var spec = properties[pname]
		var ptype := "any"
		if spec is Dictionary and spec.get("type", "") is String and not str(spec.get("type", "")).is_empty():
			ptype = str(spec["type"])
		var mark := ""
		if not required.has(pname):
			mark = "?"
		parts.append("%s%s: %s" % [str(pname), mark, ptype])
	var sig := "%s(%s)" % [fname, ", ".join(parts)]
	var desc := str(fn.get("description", ""))
	if not desc.is_empty():
		sig += ": " + desc
	return sig


# Instruction used when the endpoint rejects tools: answer in strict JSON instead.
func _json_fallback_instruction() -> String:
	var lines: Array[String] = []
	lines.append("You have no function-calling ability. Always reply with exactly one JSON object, nothing else: {\"actions\": [{\"name\": \"<action>\", \"arguments\": {<params as a JSON object>}}], \"reply\": \"<chat text>\"}.")
	lines.append("Use ONLY these actions:")
	for t in tools:
		var sig := _tool_signature(t)
		if not sig.is_empty():
			lines.append("- " + sig)
	lines.append("Put ordinary chat text in \"reply\" (\"\" if none). Use \"actions\": [] when no editor action is needed.")
	return "\n".join(lines)


# Choose effective tool
func _effective_tool_choice() -> Variant:
	if tool_choice is Dictionary:
		return tool_choice
	if tool_choice is String and tool_choice in ["auto", "none", "required"]:
		return tool_choice
	return "auto"


# Choose system prompt
func _effective_system_prompt() -> String:
	if not _json_fallback_active:
		return system_prompt
	if system_prompt.is_empty():
		return _json_fallback_instruction()
	return system_prompt + "\n\n" + _json_fallback_instruction()


# Implement context prompt
func _effective_context_prompt() -> String:
	var context := context_prompt.strip_edges()
	if context.is_empty():
		return ""
	if max_context_chars > 0 and context.length() > max_context_chars:
		context = context.left(max_context_chars).strip_edges() + "\n…(context truncated)"
	return context


# Apply tool field
func _apply_tool_fields(payload: Dictionary) -> void:
	if _json_fallback_active:
		payload["response_format"] = {"type": "json_object"}
		return
	if tools.is_empty():
		return
	payload["tools"] = tools
	payload["tool_choice"] = _effective_tool_choice()


# Cancels the HTTP request
func cancel() -> void:
	_request_generation += 1 # invalidates any scheduled retry
	_expecting_response = false
	_pending_messages = []
	_history_dropped = 0
	if _http != null:
		_http.cancel_request()
	if _streaming_active:
		_cleanup_stream()
	busy = false


# Stream
func _process(_delta: float) -> void:
	if _streaming_active:
		_poll_stream()


# Starts a stream:true request polled through HTTPClient (HTTPRequest can't stream).
func _send_stream(messages: Array, key: String) -> void:
	var url := api_url.strip_edges()
	if url.is_empty():
		url = URL
	var parts := _parse_url(url)
	if parts.is_empty():
		request_failed.emit("Invalid API endpoint URL.")
		return

	var payload_messages: Array = []
	var effective_system := _effective_system_prompt()
	if not effective_system.is_empty():
		payload_messages.append({"role": "developer", "content": effective_system})
	var context := _effective_context_prompt()
	if not context.is_empty():
		payload_messages.append({"role": "developer", "content": context})
	if _history_dropped > 0:
		payload_messages.append({"role": "developer", "content": "[History note: %d oldest %s trimmed to fit the budget.]" % [_history_dropped, "message" if _history_dropped == 1 else "messages"]})
	payload_messages.append_array(messages)

	_stream_client = HTTPClient.new()
	_stream_path = parts["path"]
	_stream_headers = PackedStringArray([
		"Authorization: Bearer %s" % key,
		"Content-Type: application/json",
		"Accept: text/event-stream",
	])
	var payload := {
		"model": model,
		"messages": payload_messages,
		"reasoning_effort": reasoning_effort,
		"max_completion_tokens": max_completion_tokens,
		"stream": true,
	}
	_apply_tool_fields(payload)
	_stream_body = JSON.stringify(payload)
	var tls_options: TLSOptions = null
	if parts["tls"]:
		tls_options = TLSOptions.client()
	var err := _stream_client.connect_to_host(parts["host"], parts["port"], tls_options)
	if err != OK:
		_stream_client = null
		var connect_message := "Could not start stream (error %d)." % err
		if _retry_attempt < max_retries:
			_schedule_retry(_backoff_delay(), connect_message)
		else:
			request_failed.emit(connect_message)
		return

	_stream_request_sent = false
	_stream_status_checked = false
	_stream_code = 0
	_stream_leftover = ""
	_stream_content = ""
	_stream_tool_calls = {}
	_stream_tool_announced = false
	_stream_error_bytes = PackedByteArray()
	_stream_deadline = Time.get_ticks_msec() + int(stream_timeout * 1000.0)
	_streaming_active = true
	set_process(true)
	busy = true


# Parse URL
static func _parse_url(url: String) -> Dictionary:
	var rest := url.strip_edges()
	var tls := false
	if rest.begins_with("https://"):
		tls = true
		rest = rest.substr("https://".length())
	elif rest.begins_with("http://"):
		rest = rest.substr("http://".length())
	else:
		return {}
	var slash := rest.find("/")
	var authority := rest if slash == -1 else rest.left(slash)
	var path := "/" if slash == -1 else rest.substr(slash)
	var host := authority
	var port := 443 if tls else 80
	var colon := authority.rfind(":")
	if colon != -1:
		host = authority.left(colon)
		var port_str := authority.substr(colon + 1)
		if not port_str.is_valid_int():
			return {}
		port = int(port_str)
	if host.is_empty():
		return {}
	return {"host": host, "port": port, "tls": tls, "path": path}


# Poll stream
func _poll_stream() -> void:
	if Time.get_ticks_msec() > _stream_deadline:
		_finish_stream_error("The request timed out. Lower reasoning effort or try again.", true)
		return
	var err := _stream_client.poll()
	if err != OK:
		_finish_stream_error("Network error (poll %d)." % err, true)
		return
	match _stream_client.get_status():
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if _stream_request_sent:
				return
			var request_err := _stream_client.request(HTTPClient.METHOD_POST, _stream_path, _stream_headers, _stream_body)
			if request_err != OK:
				_finish_stream_error("Could not start stream (error %d)." % request_err, true)
				return
			_stream_request_sent = true
		HTTPClient.STATUS_REQUESTING:
			return
		HTTPClient.STATUS_BODY:
			if not _stream_status_checked:
				_stream_status_checked = true
				_stream_code = _stream_client.get_response_code()
			_read_stream_chunks()
		_:
			# Connection closed or failed mid-stream.
			if not _stream_request_sent:
				_finish_stream_error("Could not connect to the API endpoint.", true)
			elif _stream_code != 200:
				_finish_stream_error_from_body()
			elif _stream_content.is_empty():
				_finish_stream_error("The stream ended without data.", true)
			else:
				_finish_stream_success()


# Read the stream chunks
func _read_stream_chunks() -> void:
	while _stream_client.get_status() == HTTPClient.STATUS_BODY:
		var chunk := _stream_client.read_response_body_chunk()
		if chunk.is_empty():
			break
		if _stream_code != 200:
			_stream_error_bytes.append_array(chunk)
		else:
			_append_stream_text(chunk.get_string_from_utf8())
			if not _streaming_active:
				return # [DONE] or an error finished the stream mid-read.
	if _stream_code != 200 and _stream_body_complete():
		_finish_stream_error_from_body()


# Confirm if stream body is complete
func _stream_body_complete() -> bool:
	var total := _stream_client.get_response_body_length()
	return total >= 0 and _stream_client.get_downloaded_bytes() >= total


# Append stream text
func _append_stream_text(text: String) -> void:
	_stream_leftover += text
	var lines := _stream_leftover.split("\n")
	_stream_leftover = lines[lines.size() - 1]
	for i in range(lines.size() - 1):
		if not _streaming_active:
			return
		_handle_sse_line(lines[i].strip_edges())


# Handle SSE
func _handle_sse_line(line: String) -> void:
	if line.is_empty() or line.begins_with(":"):
		return
	if not line.begins_with("data:"):
		return
	var payload := line.substr("data:".length()).strip_edges()
	if payload.is_empty():
		return
	if payload == "[DONE]":
		_finish_stream_success()
		return
	var parsed = JSON.parse_string(payload)
	if not parsed is Dictionary:
		return
	if parsed.get("error") != null:
		_finish_stream_error(_stream_error_message(parsed["error"]))
		return
	var choices = parsed.get("choices", [])
	if not choices is Array or choices.is_empty():
		return
	var first = choices[0]
	if not first is Dictionary:
		return
	var delta = first.get("delta", {})
	if not delta is Dictionary:
		return
	var call_deltas = delta.get("tool_calls", [])
	if call_deltas is Array:
		for raw in call_deltas:
			_accumulate_tool_delta(raw)
		if _stream_content.is_empty() and not _stream_tool_announced and not _stream_tool_calls.is_empty():
			_stream_tool_announced = true
			stream_updated.emit("Preparing actions…")
	var piece = delta.get("content", "")
	if piece is String and not piece.is_empty():
		_stream_content += piece
		stream_updated.emit(_stream_content)


# Get stream error message
static func _stream_error_message(err) -> String:
	var message := "Stream error."
	if err is Dictionary:
		message = str(err.get("message", message))
		var code := str(err.get("code", ""))
		if not code.is_empty():
			message = "%s: %s" % [code, message]
	elif err is String and not err.strip_edges().is_empty():
		message = err.strip_edges()
	return message


# Finish stream
func _finish_stream_success() -> void:
	var content := _stream_content
	var tool_slots: Dictionary = _stream_tool_calls
	_cleanup_stream()
	if not tool_slots.is_empty():
		var raw_calls: Array = []
		var indexes := tool_slots.keys()
		indexes.sort()
		for idx in indexes:
			var slot: Dictionary = tool_slots[idx]
			raw_calls.append({
				"id": str(slot.get("id", "")),
				"type": "function",
				"function": {
					"name": str(slot.get("name", "")),
					"arguments": str(slot.get("arguments", "")),
				},
			})
		_handle_native_tool_calls(raw_calls, content)
		return
	if content.is_empty():
		request_failed.emit("Response had empty content.")
	else:
		response_received.emit(content)


# Emit stream error message
func _finish_stream_error(message: String, retryable := false) -> void:
	_cleanup_stream()
	if retryable and _retry_attempt < max_retries:
		_schedule_retry(_backoff_delay(), message)
	else:
		request_failed.emit(message)


# Emit stream error from body
func _finish_stream_error_from_body() -> void:
	var parsed = null
	if not _stream_error_bytes.is_empty():
		parsed = JSON.parse_string(_stream_error_bytes.get_string_from_utf8())
	var headers := PackedStringArray()
	var code := _stream_code
	if _stream_client != null:
		headers = _stream_client.get_response_headers()
	_cleanup_stream()
	if _maybe_start_json_fallback(code, parsed):
		return
	if _is_retryable_code(code) and _retry_attempt < max_retries:
		var wait := 0.0
		if code == 429:
			wait = _parse_retry_after(headers)
		_schedule_retry(_backoff_delay(maxf(wait, 0.0)), _describe_error(code, parsed, headers))
	else:
		request_failed.emit(_describe_error(code, parsed, headers))


# Cleanup stream
func _cleanup_stream() -> void:
	_streaming_active = false
	_stream_tool_calls = {}
	_stream_tool_announced = false
	set_process(false)
	if _stream_client != null:
		_stream_client.close()
		_stream_client = null
	busy = false


# Schedule a retry
func _schedule_retry(delay: float, terminal_message: String) -> void:
	if get_tree() == null:
		busy = false
		request_failed.emit(terminal_message)
		return
	_retry_attempt += 1
	busy = true
	var generation := _request_generation
	print("[GdAI] Transient failure; retrying in %.1fs (attempt %d of %d)." % [delay, _retry_attempt + 1, max_retries + 1])
	retry_scheduled.emit(_retry_attempt + 1, max_retries + 1, delay)
	get_tree().create_timer(delay).timeout.connect(func():
		if generation != _request_generation:
			return # cancelled or superseded while waiting
		_start_request()
	)


# Set backoff delay
func _backoff_delay(extra_min := 0.0) -> float:
	var delay := minf(retry_base_delay * pow(2.0, float(_retry_attempt)), retry_max_delay)
	return maxf(delay, extra_min) + randf() * 0.5


# Return if a code is a retryable code
static func _is_retryable_code(code: int) -> bool:
	return code == 429 or code == 500 or code == 502 or code == 503 or code == 504


# Return if a HTTP request is retryable
static func _is_retryable_result(result: int) -> bool:
	return result in [
		HTTPRequest.RESULT_TIMEOUT,
		HTTPRequest.RESULT_CANT_CONNECT,
		HTTPRequest.RESULT_CANT_RESOLVE,
		HTTPRequest.RESULT_CONNECTION_ERROR,
		HTTPRequest.RESULT_NO_RESPONSE,
		HTTPRequest.RESULT_REQUEST_FAILED,
	]


# Parse error
static func _parse_retry_after(headers: PackedStringArray) -> float:
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var pos := h.find(":")
			if pos == -1:
				return -1.0
			var value := h.substr(pos + 1).strip_edges()
			if value.is_valid_float() or value.is_valid_int():
				return maxf(float(value), 0.0)
			return -1.0
	return -1.0


# Validates one parsed call against the declared tools. Returns "" when valid,
# otherwise a human-readable reason. Static so Phase 2 can reuse it at execution time.
static func validate_tool_call(tools_defs: Array, call_name: String, args: Variant) -> String:
	var fn_def = null
	for t in tools_defs:
		if t is Dictionary and str(t.get("type", "function")) == "function":
			var f = t.get("function", {})
			if f is Dictionary and str(f.get("name", "")) == call_name:
				fn_def = f
				break
	if fn_def == null:
		return "unknown action (not in the declared tools)"
	if not args is Dictionary:
		return "arguments must be an object"
	var params = fn_def.get("parameters", {})
	if not params is Dictionary:
		return ""
	var properties = params.get("properties", {})
	if not properties is Dictionary:
		properties = {}
	var required = params.get("required", [])
	if required is Array:
		for req in required:
			if not args.has(req):
				return "missing required parameter '%s'" % str(req)
	var allow_extra := bool(params.get("additionalProperties", true))
	for pname in args.keys():
		if not properties.has(pname):
			if not allow_extra:
				return "unknown parameter '%s'" % str(pname)
			continue
		var spec = properties[pname]
		if not spec is Dictionary or not spec.has("type"):
			continue
		var problem := _check_json_type(args[pname], str(spec["type"]))
		if not problem.is_empty():
			return "parameter '%s' %s" % [str(pname), problem]
	return ""


static func _check_json_type(value: Variant, want: String) -> String:
	var is_bool := value is bool
	match want:
		"string":
			if value is String:
				return ""
			return "must be a string"
		"integer":
			if (value is int) and not is_bool:
				return ""
			return "must be an integer"
		"number":
			if ((value is int) or (value is float)) and not is_bool:
				return ""
			return "must be a number"
		"boolean":
			if is_bool:
				return ""
			return "must be a boolean"
		"object":
			if value is Dictionary:
				return ""
			return "must be an object"
		"array":
			if value is Array:
				return ""
			return "must be an array"
		"null":
			if value == null:
				return ""
			return "must be null"
		_:
			return ""


# Normalizes message content (string, parts array, or null) to plain text.
static func _content_to_text(content) -> String:
	if content == null:
		return ""
	if content is String:
		return content
	if content is Array:
		var parts: Array[String] = []
		for part in content:
			if part is String:
				parts.append(part)
			elif part is Dictionary:
				parts.append(str(part.get("text", part.get("content", ""))))
		return "".join(parts)
	return str(content)


# Keeps the most recent history within both budgets. Never mutates the input.
# Returns {"messages": [...], "dropped": n}. At least one message is always kept.
static func trim_history(messages: Array, max_messages: int, max_chars: int) -> Dictionary:
	var kept: Array = []
	var chars := 0
	var count := 0
	for i in range(messages.size() - 1, -1, -1):
		var msg = messages[i]
		if max_messages > 0 and count >= max_messages:
			break
		var text := ""
		if msg is Dictionary:
			text = _content_to_text(msg.get("content", ""))
		if max_chars > 0 and count > 0 and chars + text.length() > max_chars:
			break
		kept.push_front(msg)
		chars += text.length()
		count += 1
	# Keep payloads starting on a user turn (Phase 2: extend for tool pairs).
	if not kept.is_empty() and kept[0] is Dictionary and str(kept[0].get("role", "")) == "assistant":
		kept.pop_front()
	return {"messages": kept, "dropped": messages.size() - kept.size()}


# Check if a tool might be unsupported
static func _looks_like_tools_unsupported(parsed) -> bool:
	if not parsed is Dictionary:
		return false
	var err = parsed.get("error", null)
	var code_str := ""
	var message := ""
	if err is Dictionary:
		code_str = str(err.get("code", ""))
		message = str(err.get("message", ""))
	elif err is String:
		message = err
	var hay := (code_str + " " + message).to_lower()
	if hay.strip_edges().is_empty() or not hay.contains("tool"):
		return false
	return hay.contains("support") or hay.contains("unknown") or hay.contains("invalid") \
		or hay.contains("unrecognized") or hay.contains("parameter") or hay.contains("field")


# If the endpoint rejected the tools parameter, re-issue once as JSON-mode
# single-shot. Returns true when the fallback request was started.
func _maybe_start_json_fallback(code: int, parsed) -> bool:
	if _json_fallback_active or tools.is_empty():
		return false
	if code != 400:
		return false
	if not _looks_like_tools_unsupported(parsed):
		return false
	_json_fallback_active = true
	print("[GdAI] Endpoint rejected tools; retrying in JSON mode.")
	_start_request()
	return true


# Handle a native tool call
func _handle_native_tool_calls(raw_calls: Array, preamble: String) -> void:
	var calls: Array = []
	var stamp := Time.get_ticks_msec()
	var index := 0
	for raw in raw_calls:
		if not raw is Dictionary:
			request_failed.emit("Invalid tool call: entry %d is not an object." % index)
			return
		var fn = raw.get("function", {})
		if not fn is Dictionary:
			request_failed.emit("Invalid tool call: entry %d has no function object." % index)
			return
		var fname := str(fn.get("name", ""))
		var args_raw = fn.get("arguments", "")
		var args := {}
		if args_raw is String:
			if not args_raw.strip_edges().is_empty():
				var parsed_args = JSON.parse_string(args_raw)
				if parsed_args == null or not parsed_args is Dictionary:
					request_failed.emit("Invalid action '%s': arguments are not a JSON object." % fname)
					return
				args = parsed_args
		elif args_raw is Dictionary:
			args = args_raw
		else:
			request_failed.emit("Invalid action '%s': arguments must be an object." % fname)
			return
		var problem := validate_tool_call(tools, fname, args)
		if not problem.is_empty():
			request_failed.emit("Invalid action '%s': %s" % [fname, problem])
			return
		var call_id := str(raw.get("id", ""))
		if call_id.is_empty():
			call_id = "call_native_%d_%d" % [stamp, index]
		calls.append({"id": call_id, "name": fname, "arguments": args})
		index += 1
	if calls.is_empty():
		if preamble.is_empty():
			request_failed.emit("Response had empty content.")
		else:
			response_received.emit(preamble)
		return
	tool_calls_received.emit(calls, preamble)


# Handle fallback
func _handle_fallback_json(text: String) -> void:
	if text.is_empty():
		request_failed.emit("Response had empty content.")
		return
	var parsed = JSON.parse_string(text)
	if parsed == null:
		response_received.emit(text)
		return
	if not parsed is Dictionary:
		request_failed.emit("Invalid action JSON: top level must be an object.")
		return
	if not parsed.has("actions"):
		request_failed.emit("Invalid action JSON: missing \"actions\".")
		return
	var actions = parsed["actions"]
	if not actions is Array:
		request_failed.emit("Invalid action JSON: \"actions\" must be an array.")
		return
	var preamble := str(parsed.get("reply", ""))
	if actions.is_empty():
		if preamble.is_empty():
			request_failed.emit("Response had empty content.")
		else:
			response_received.emit(preamble)
		return
	var calls: Array = []
	var stamp := Time.get_ticks_msec()
	var index := 0
	for action in actions:
		if not action is Dictionary:
			request_failed.emit("Invalid action JSON: actions[%d] must be an object." % index)
			return
		var fname := str(action.get("name", ""))
		var args = action.get("arguments", {})
		var problem := validate_tool_call(tools, fname, args)
		if not problem.is_empty():
			request_failed.emit("Invalid action '%s': %s" % [fname, problem])
			return
		calls.append({
			"id": "call_json_%d_%d" % [stamp, index],
			"name": fname,
			"arguments": args,
		})
		index += 1
	tool_calls_received.emit(calls, preamble)


# Accumulate tool
func _accumulate_tool_delta(raw) -> void:
	if not raw is Dictionary:
		return
	var idx := int(raw.get("index", 0))
	if not _stream_tool_calls.has(idx):
		_stream_tool_calls[idx] = {"id": "", "name": "", "arguments": ""}
	var slot: Dictionary = _stream_tool_calls[idx]
	var rid := str(raw.get("id", ""))
	if not rid.is_empty():
		slot["id"] = rid
	var rfn = raw.get("function", {})
	if rfn is Dictionary:
		var rname := str(rfn.get("name", ""))
		if not rname.is_empty():
			slot["name"] = rname
		var rargs = rfn.get("arguments", "")
		if rargs is String:
			slot["arguments"] = str(slot["arguments"]) + rargs


# Handles what happens when a request is complete
func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _expecting_response:
		return # stale completion after cancel; a retry timer or newer request owns the state
	_expecting_response = false
	busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		var net_message := "Network error (result %d)." % result
		if _is_retryable_result(result) and _retry_attempt < max_retries:
			_schedule_retry(_backoff_delay(), net_message)
		else:
			request_failed.emit(net_message)
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())

	# If there is an error code, check what the error code was
	if code != 200:
		if _maybe_start_json_fallback(code, parsed):
			return
		if _is_retryable_code(code) and _retry_attempt < max_retries:
			var wait := 0.0
			if code == 429:
				wait = _parse_retry_after(headers)
			_schedule_retry(_backoff_delay(maxf(wait, 0.0)), _describe_error(code, parsed, headers))
		else:
			request_failed.emit(_describe_error(code, parsed, headers))
		return

	# Handle an unexpected response
	if not parsed is Dictionary:
		request_failed.emit("Unexpected response from server.")
		return

	# Get choices from response
	var choices = parsed.get("choices", [])
	if not choices is Array or choices.is_empty():
		request_failed.emit("Response had no choices.")
		return

	# Get the message and send the response message (or structured actions) to the dock
	var first = choices[0]
	if not first is Dictionary:
		request_failed.emit("Unexpected response from server.")
		return
	var message = first.get("message", {})
	if not message is Dictionary:
		request_failed.emit("Unexpected response from server.")
		return
	var raw_calls = message.get("tool_calls", [])
	var text := _content_to_text(message.get("content", ""))
	if raw_calls is Array and not raw_calls.is_empty():
		_handle_native_tool_calls(raw_calls, text)
		return
	if _json_fallback_active:
		_handle_fallback_json(text)
		return
	if text.is_empty():
		request_failed.emit("Response had empty content.")
		return
	response_received.emit(text)


# Describes the error based on error code
func _describe_error(code: int, parsed, headers: PackedStringArray) -> String:
	var message := "HTTP %d" % code
	var err_code := ""
	if parsed is Dictionary:
		var err = parsed.get("error", null)
		if err is Dictionary:
			message = str(err.get("message", message))
			err_code = str(err.get("code", ""))
		elif err is String and not err.strip_edges().is_empty():
			message = err.strip_edges()
	# Prefer "code: message" (e.g. "invalid_api_key: Unauthorized") when distinct.
	var shown := message
	if not err_code.is_empty() and err_code.to_lower() != message.to_lower():
		shown = "%s: %s" % [err_code, message]

	# Return the error code reasoning
	match code:
		400:
			return "Bad request. (%s)" % shown
		401:
			return "Invalid or missing API key. (%s) Use a key from dev.meta.ai API keys (starts with LLM_), add a billing card (no free tier), fully quit and relaunch Godot. Endpoint: %s" % [shown, api_url]
		402:
			return "Billing issue on your Meta Model API account. (%s)" % shown
		403:
			return "Forbidden. (%s)" % shown
		404:
			return "Model or endpoint not found. (%s)" % shown
		429:
			for h in headers:
				if h.to_lower().begins_with("retry-after:"):
					var pos := h.find(":")
					var value := h.substr(pos + 1).strip_edges() if pos != -1 else ""
					if value.is_empty():
						return "Rate limited. Try again shortly."
					return "Rate limited. Retry in %s seconds." % value
			return "Rate limited. Try again shortly."
		500, 502, 503:
			return "Server error. Try again shortly. (%s)" % shown
		504:
			return "The request timed out. Lower reasoning effort or try again."
		_:
			return shown
