@tool
extends RefCounted

class_name ChatStore


const DIR := "user://gd_ai/chats" # Stored in per-project user data folder outside project, so chats don’t end up in version control


static func new_chat() -> Dictionary:
	var now := Time.get_unix_time_from_system()
	return {
		"id": str(int(now * 1000)),
		"title": "New chat",
		"created": now,
		"updated": now,
		"messages": [],
	}


static func save_chat(chat: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	chat["updated"] = Time.get_unix_time_from_system()
	var file := FileAccess.open("%s/%s.json" % [DIR, chat["id"]], FileAccess.WRITE)
	if file == null:
		push_error("GdAI: could not save chat (error %d)" % FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(chat, "\t"))


static func load_chat(id: String) -> Dictionary:
	var path := "%s/%s.json" % [DIR, id]
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


static func list_chats() -> Array[Dictionary]:
	DirAccess.make_dir_recursive_absolute(DIR)
	var result: Array[Dictionary] = []
	for file_name in DirAccess.get_files_at(DIR):
		if file_name.get_extension() != "json":
			continue
		var chat := load_chat(file_name.get_basename())
		if not chat.is_empty():
			result.append(chat)
	# Most recently updated first
	result.sort_custom(func(a, b): return a["updated"] > b["updated"])
	return result


static func delete_chat(id: String) -> void:
	DirAccess.remove_absolute("%s/%s.json" % [DIR, id])
