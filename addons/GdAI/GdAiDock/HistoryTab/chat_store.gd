@tool
extends RefCounted

class_name ChatStore


const DIR := "user://gd_ai/chats" # Per-project chat storage kept outside version control.


## Creates and returns a new chat dictionary with timestamps and empty messages.
static func new_chat() -> Dictionary:
	var now := Time.get_unix_time_from_system() # Capture the current system time once.

	# Build the initial chat dictionary.
	return {
		# Use millisecond timestamp as unique id.
		"id": str(int(now * 1000)),
		"title": "New chat",
		"created": now,
		"updated": now,
		"messages": [],
	}


## Updates the timestamp and persists the given chat dictionary to disk.
static func save_chat(chat: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(DIR) # Ensure the chat storage directory exists.
	chat["updated"] = Time.get_unix_time_from_system() # Stamp the current update time.
	var file := FileAccess.open("%s/%s.json" % [DIR, chat["id"]], FileAccess.WRITE) # Open the chat file for writing.

	# Report failures to open the chat file.
	if file == null:
		push_error("GdAI: could not save chat (error %d)" % FileAccess.get_open_error())
		return

	file.store_string(JSON.stringify(chat, "\t")) # Write the chat JSON to disk.


## Loads and returns the chat dictionary for the given id, or empty.
static func load_chat(id: String) -> Dictionary:
	var path := "%s/%s.json" % [DIR, id] # Build the path to the chat file.

	# Return empty when the chat file is missing.
	if not FileAccess.file_exists(path):
		return {}

	# Parse the stored chat JSON.
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	# Fall back to empty on invalid data.
	return parsed if parsed is Dictionary else {}


## Loads all stored chats sorted by most recently updated first.
static func list_chats() -> Array[Dictionary]:
	DirAccess.make_dir_recursive_absolute(DIR) # Ensure the chat storage directory exists.
	var result: Array[Dictionary] = []

	# Inspect every file in the storage directory.
	for file_name in DirAccess.get_files_at(DIR):
		# Skip non-JSON files.
		if file_name.get_extension() != "json":
			continue
		# Load the chat by file basename.
		var chat := load_chat(file_name.get_basename())

		# Collect only successfully loaded chats.
		if not chat.is_empty():
			result.append(chat)
	
	# Sort most recently updated chats first.
	result.sort_custom(func(a, b): return a["updated"] > b["updated"])
	return result


## Deletes the stored chat file matching the given chat id.
static func delete_chat(id: String) -> void:
	DirAccess.remove_absolute("%s/%s.json" % [DIR, id]) # Remove the stored chat file.
