@tool
extends RefCounted

class_name ChatStore


const DIR := "user://gd_ai/chats" # Stored in per-project user data folder outside project, so chats don’t end up in version control


# Creates a new chat
static func new_chat() -> Dictionary:
	var now := Time.get_unix_time_from_system() # Get current system time

	# Create new chat with system time
	return {
		"id": str(int(now * 1000)),
		"title": "New chat",
		"created": now,
		"updated": now,
		"messages": [],
	}


# Saves a chat
static func save_chat(chat: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(DIR) # Set directory path
	chat["updated"] = Time.get_unix_time_from_system() # Update time
	var file := FileAccess.open("%s/%s.json" % [DIR, chat["id"]], FileAccess.WRITE) # Write to file

	# Handle not being able to save chat
	if file == null:
		push_error("GdAI: could not save chat (error %d)" % FileAccess.get_open_error())
		return

	file.store_string(JSON.stringify(chat, "\t")) # Store chat


# Handle loading chat
static func load_chat(id: String) -> Dictionary:
	var path := "%s/%s.json" % [DIR, id] # Get path

	# Handle not being able to find path
	if not FileAccess.file_exists(path):
		return {}

	# Return chat
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


# Handle loading chat list
static func list_chats() -> Array[Dictionary]:
	DirAccess.make_dir_recursive_absolute(DIR) # Loop through directory
	var result: Array[Dictionary] = []

	# Iterate through directory
	for file_name in DirAccess.get_files_at(DIR):
		# Skip files that are not a json
		if file_name.get_extension() != "json":
			continue
		# Load chat by name
		var chat := load_chat(file_name.get_basename())

		# If a chat is not empty, append to result
		if not chat.is_empty():
			result.append(chat)
	
	# Most recently updated first
	result.sort_custom(func(a, b): return a["updated"] > b["updated"])
	return result


# Handle deleting chat
static func delete_chat(id: String) -> void:
	DirAccess.remove_absolute("%s/%s.json" % [DIR, id]) # Delete chat
