@tool
extends Node

class_name AiClient

signal response_received(text: String)
signal request_failed(message: String)
signal stream_updated(full_text: String)

const URL := "https://api.meta.ai/v1/chat/completions" # API Url

var api_key := ""
var model := "muse-spark-1.3-contributor"
var reasoning_effort := "minimal"   # "minimal" | "low" | "medium" | "high" | "xhigh" ("none" is rejected)
var system_prompt := ""         # sent as a developer message, never stored in chat history
var max_completion_tokens := 64 #2048
var busy := false
var api_url := URL # override (e.g. via MODEL_API_URL) to test another endpoint without editing code
var streaming := false # when true, send() uses stream:true with chunked SSE append
var stream_timeout := 120.0 # seconds for the whole streamed request

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


# Generate a new HTTP request upon instantiation
func _ready() -> void:
	_ensure_http()
	set_process(false) # enabled only while a stream is being polled


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
	if streaming:
		_send_stream(messages, key)
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
	if _streaming_active:
		_cleanup_stream()
	busy = false


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
	if not system_prompt.is_empty():
		payload_messages.append({"role": "developer", "content": system_prompt})
	payload_messages.append_array(messages)

	_stream_client = HTTPClient.new()
	_stream_path = parts["path"]
	_stream_headers = PackedStringArray([
		"Authorization: Bearer %s" % key,
		"Content-Type: application/json",
		"Accept: text/event-stream",
	])
	_stream_body = JSON.stringify({
		"model": model,
		"messages": payload_messages,
		"reasoning_effort": reasoning_effort,
		"max_completion_tokens": max_completion_tokens,
		"stream": true,
	})
	var err := _stream_client.connect_to_host(parts["host"], parts["port"], parts["tls"])
	if err != OK:
		_stream_client = null
		request_failed.emit("Could not start stream (error %d)." % err)
		return

	_stream_request_sent = false
	_stream_status_checked = false
	_stream_code = 0
	_stream_leftover = ""
	_stream_content = ""
	_stream_error_bytes = PackedByteArray()
	_stream_deadline = Time.get_ticks_msec() + int(stream_timeout * 1000.0)
	_streaming_active = true
	set_process(true)
	busy = true


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


func _poll_stream() -> void:
	if Time.get_ticks_msec() > _stream_deadline:
		_finish_stream_error("The request timed out. Lower reasoning effort or try again.")
		return
	var err := _stream_client.poll()
	if err != OK:
		_finish_stream_error("Network error (poll %d)." % err)
		return
	match _stream_client.get_status():
		HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
			return
		HTTPClient.STATUS_CONNECTED:
			if _stream_request_sent:
				return
			var request_err := _stream_client.request(HTTPClient.METHOD_POST, _stream_path, _stream_headers, _stream_body)
			if request_err != OK:
				_finish_stream_error("Could not start stream (error %d)." % request_err)
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
				_finish_stream_error("Could not connect to the API endpoint.")
			elif _stream_code != 200:
				_finish_stream_error_from_body()
			elif _stream_content.is_empty():
				_finish_stream_error("The stream ended without data.")
			else:
				_finish_stream_success()


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


func _stream_body_complete() -> bool:
	var total := _stream_client.get_response_body_length()
	return total >= 0 and _stream_client.get_downloaded_bytes() >= total


func _append_stream_text(text: String) -> void:
	_stream_leftover += text
	var lines := _stream_leftover.split("\n")
	_stream_leftover = lines[lines.size() - 1]
	for i in range(lines.size() - 1):
		if not _streaming_active:
			return
		_handle_sse_line(lines[i].strip_edges())


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
	var piece = delta.get("content", "")
	if piece is String and not piece.is_empty():
		_stream_content += piece
		stream_updated.emit(_stream_content)


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


func _finish_stream_success() -> void:
	var content := _stream_content
	_cleanup_stream()
	if content.is_empty():
		request_failed.emit("Response had empty content.")
	else:
		response_received.emit(content)


func _finish_stream_error(message: String) -> void:
	_cleanup_stream()
	request_failed.emit(message)


func _finish_stream_error_from_body() -> void:
	var parsed = null
	if not _stream_error_bytes.is_empty():
		parsed = JSON.parse_string(_stream_error_bytes.get_string_from_utf8())
	var headers := PackedStringArray()
	var code := _stream_code
	if _stream_client != null:
		headers = _stream_client.get_response_headers()
	_cleanup_stream()
	request_failed.emit(_describe_error(code, parsed, headers))


func _cleanup_stream() -> void:
	_streaming_active = false
	set_process(false)
	if _stream_client != null:
		_stream_client.close()
		_stream_client = null
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
