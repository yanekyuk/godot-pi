@tool
extends TextEdit
## Clipboard images live in memory. Only images with a marker still in the draft
## are sent; keeping removed entries until reset also makes undo restore them.

signal image_paste_failed(message: String)

var _images := {} # marker id -> RPC ImageContent
var _next_image_id := 0


func _paste(caret_index: int) -> void:
	if not editable:
		return
	if DisplayServer.clipboard_has_image():
		var image := DisplayServer.clipboard_get_image()
		if not insert_image(image, caret_index):
			image_paste_failed.emit("Could not read the clipboard image. Copy the image itself, not its file path.")
		return
	# Preserve ordinary text paste, including selection replacement.
	insert_text_at_caret(DisplayServer.clipboard_get(), caret_index)


func insert_image(image: Image, caret_index := -1) -> bool:
	if image == null or image.is_empty():
		return false
	var png := image.save_png_to_buffer()
	if png.is_empty():
		return false
	_next_image_id += 1
	_images[_next_image_id] = {"type": "image", "data": Marshalls.raw_to_base64(png), "mimeType": "image/png"}
	insert_text_at_caret("[image #%d]" % _next_image_id, caret_index)
	return true


## Renumber surviving markers in text order, matching the RPC images array.
func get_prompt() -> Dictionary:
	var images: Array = []
	var ids := {}
	for match_ in _marker_regex().search_all(text):
		var id := int(match_.get_string(1))
		if _images.has(id) and not ids.has(id):
			images.append(_images[id].duplicate())
			ids[id] = images.size()
	return {"text": _replace_markers(text, ids), "images": images}


func reset_draft() -> void:
	clear()
	clear_undo_history()
	_images.clear()
	_next_image_id = 0


## Append a rejected/unqueued draft without overwriting newer input or colliding IDs.
func restore_prompt(draft: Dictionary) -> void:
	var ids := {}
	var images: Array = draft.get("images", [])
	for i in images.size():
		_next_image_id += 1
		_images[_next_image_id] = images[i].duplicate()
		ids[i + 1] = _next_image_id
	set_caret_line(get_line_count() - 1)
	set_caret_column(get_line(get_line_count() - 1).length())
	if not text.is_empty():
		insert_text_at_caret("\n\n")
	insert_text_at_caret(_replace_markers(str(draft.get("text", "")), ids))


static func _marker_regex() -> RegEx:
	var regex := RegEx.new()
	regex.compile("\\[image #(\\d+)\\]")
	return regex


static func _replace_markers(source: String, ids: Dictionary) -> String:
	var result := ""
	var offset := 0
	for match_ in _marker_regex().search_all(source):
		result += source.substr(offset, match_.get_start() - offset)
		var id := int(match_.get_string(1))
		result += ("[image #%d]" % ids[id]) if ids.has(id) else match_.get_string()
		offset = match_.get_end()
	return result + source.substr(offset)


static func decode_image(content: Dictionary) -> Image:
	var bytes := Marshalls.base64_to_raw(str(content.get("data", "")))
	if bytes.is_empty():
		return null
	var image := Image.new()
	var err := ERR_UNAVAILABLE
	match str(content.get("mimeType", "")):
		"image/png":
			err = image.load_png_from_buffer(bytes)
		"image/jpeg":
			err = image.load_jpg_from_buffer(bytes)
		"image/webp":
			err = image.load_webp_from_buffer(bytes)
	return image if err == OK else null
