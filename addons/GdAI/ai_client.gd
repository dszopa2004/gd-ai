@tool
extends Node

class_name AiClient

signal response_received(text: String)
signal request_failed(message: String)

const URL := "https://api.meta.ai/v1/chat/completions" # API Url

var api_key := ""
var model := "muse-spark-1.3"
var reasoning_effort := "low"   # "minimal" | "low" | "medium" | "high" | "xhigh" ("none" is rejected)
var system_prompt := ""         # sent as a developer message, never stored in chat history
var max_completion_tokens := 2048
var busy := false

var _http: HTTPRequest


# Generate a new HTTP request upon instantiation
func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


# Sends a message to ai with adjusted settings
# Throw error if HTTP request could not be started
func send(messages: Array) -> void:
	if busy:
		return
	if api_key.is_empty():
		request_failed.emit("No API key set.")
		return

	var payload_messages: Array = []
	if not system_prompt.is_empty():
		payload_messages.append({"role": "developer", "content": system_prompt})
	payload_messages.append_array(messages)

	var headers := [
		"Authorization: Bearer %s" % api_key,
		"Content-Type: application/json",
	]
	var body := JSON.stringify({
		"model": model,
		"messages": payload_messages,
		"reasoning_effort": reasoning_effort,
		"max_completion_tokens": max_completion_tokens,
	})

	var err := _http.request(URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		request_failed.emit("Could not start request (error %d)." % err)
		return
	busy = true


# Cancels the HTTP request
func cancel() -> void:
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
	var choices: Array = parsed.get("choices", [])
	if choices.is_empty():
		request_failed.emit("Response had no choices.")
		return

	# Get the message and send the response message to the dock
	var content = choices[0].get("message", {}).get("content", "")
	response_received.emit(content if content is String else str(content))


# Describes the error based on error code
func _describe_error(code: int, parsed, headers: PackedStringArray) -> String:
	var message := "HTTP %d" % code
	if parsed is Dictionary and parsed.get("error") is Dictionary:
		message = str(parsed["error"].get("message", message))

	# Return the error code reasoning
	match code:
		401:
			return "Invalid or missing API key. (%s)" % message
		402:
			return "Billing issue on your Meta Model API account. (%s)" % message
		429:
			for h in headers:
				if h.to_lower().begins_with("retry-after:"):
					return "Rate limited. Retry in %s seconds." % h.get_slice(":", 1).strip_edges()
			return "Rate limited. Try again shortly."
		504:
			return "The request timed out. Lower reasoning effort or use streaming."
		_:
			return message
