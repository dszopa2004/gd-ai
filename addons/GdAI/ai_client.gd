@tool
extends Node

class_name AiClient

signal response_received(text: String)
signal request_failed(message: String)

const URL := "https://api.meta.ai/v1/chat/completions" # API Url

var api_key := ""
var model := "muse-spark-1.3"
var reasoning_effort := "minimal"   # "minimal" | "low" | "medium" | "high" | "xhigh" ("none" is rejected)
var system_prompt := ""         # sent as a developer message, never stored in chat history
var max_completion_tokens := 64 #2048
var busy := false
var api_url := URL # override (e.g. via MODEL_API_URL) to test another endpoint without editing code

var _http: HTTPRequest


# Generate a new HTTP request upon instantiation
func _ready() -> void:
	_ensure_http()


func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	_http.timeout = 60.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


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
	_ensure_http()
	if _http == null:
		request_failed.emit("HTTP client is not ready.")
		return

	var payload_messages: Array = []
	if not system_prompt.is_empty():
		payload_messages.append({"role": "developer", "content": system_prompt})
	payload_messages.append_array(messages)

	var headers := PackedStringArray([
		"Authorization: Bearer %s" % key,
		"Content-Type: application/json",
	])
	var body := JSON.stringify({
		"model": model,
		"messages": payload_messages,
		"reasoning_effort": reasoning_effort,
		"max_completion_tokens": max_completion_tokens,
	})

	var url := api_url.strip_edges()
	if url.is_empty():
		url = URL
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		request_failed.emit("Could not start request (error %d)." % err)
		return
	busy = true


# Tolerate pasting the whole header value or a quoted string.
static func _sanitize_key(raw: String) -> String:
	var key := raw.strip_edges()
	if key.to_lower().begins_with("bearer "):
		key = key.substr("bearer ".length()).strip_edges()
	if key.length() >= 2:
		var first := key[0]
		var last := key[key.length() - 1]
		if (first == '"' and last == '"') or (first == "'" and last == "'"):
			key = key.substr(1, key.length() - 2).strip_edges()
	return key


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
	return "len=%d %s…%s" % [key.length(), key.left(4), key.right(2)]


# Cancels the HTTP request
func cancel() -> void:
	if _http != null:
		_http.cancel_request()
	busy = false


# Handles what happens when a request is complete
func _on_request_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Network error (result %d)." % result)
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())

	# If there is an error code, check what the error code was
	if code != 200:
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

	# Get the message and send the response message to the dock
	var first = choices[0]
	if not first is Dictionary:
		request_failed.emit("Unexpected response from server.")
		return
	var message = first.get("message", {})
	if not message is Dictionary:
		request_failed.emit("Unexpected response from server.")
		return
	var content = message.get("content", "")
	if content is Array:
		var parts: Array[String] = []
		for part in content:
			if part is String:
				parts.append(part)
			elif part is Dictionary:
				parts.append(str(part.get("text", part.get("content", ""))))
		content = "".join(parts)
	if not content is String:
		content = str(content)
	if content.is_empty():
		request_failed.emit("Response had empty content.")
		return
	response_received.emit(content)


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
			return "The request timed out. Lower reasoning effort or use streaming."
		_:
			return shown
