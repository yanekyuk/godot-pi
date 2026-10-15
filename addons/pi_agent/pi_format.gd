@tool
extends RefCounted
## Text helpers: minimal Markdown -> BBCode, ANSI stripping, message content extraction.

static var _re_ansi: RegEx
static var _re_inline_code: RegEx
static var _re_bold: RegEx
static var _re_heading: RegEx
static var _re_bullet: RegEx
static var _re_link: RegEx


static func _init_regex() -> void:
	if _re_ansi:
		return
	_re_ansi = RegEx.create_from_string("\u001b\\[[0-9;?]*[ -/]*[@-~]|\u001b\\][^\u0007]*\u0007")
	_re_inline_code = RegEx.create_from_string("`([^`\n]+)`")
	_re_bold = RegEx.create_from_string("\\*\\*([^*\n]+)\\*\\*")
	_re_heading = RegEx.create_from_string("^#{1,6}\\s+(.*)$")
	_re_bullet = RegEx.create_from_string("^(\\s*)[-*+]\\s+")
	_re_link = RegEx.create_from_string("\\[lb\\]([^\\]\n]+)\\]\\(([^)\\s]+)\\)")


static func strip_ansi(s: String) -> String:
	_init_regex()
	return _re_ansi.sub(s, "", true)


static func escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")


## Converts a useful subset of Markdown into RichTextLabel BBCode.
static func markdown_to_bbcode(md: String, code_color: Color) -> String:
	_init_regex()
	var out := PackedStringArray()
	var in_fence := false
	var fence := PackedStringArray()
	var code_hex := code_color.to_html(false)
	for raw_line in md.split("\n"):
		var line: String = raw_line
		if line.strip_edges().begins_with("```"):
			if in_fence:
				out.append("[indent][code][color=#%s]%s[/color][/code][/indent]" % [code_hex, escape_bbcode("\n".join(fence))])
				fence.clear()
				in_fence = false
			else:
				in_fence = true
			continue
		if in_fence:
			fence.append(line)
			continue
		line = escape_bbcode(line)
		var h := _re_heading.search(line)
		if h:
			out.append("[b]%s[/b]" % h.get_string(1))
			continue
		var b := _re_bullet.search(line)
		if b:
			line = b.get_string(1) + "  • " + line.substr(b.get_end())
		line = _re_inline_code.sub(line, "[code][color=#%s]$1[/color][/code]" % code_hex, true)
		line = _re_bold.sub(line, "[b]$1[/b]", true)
		line = _re_link.sub(line, "[url=$2]$1[/url]", true)
		out.append(line)
	if in_fence:
		# Unterminated fence while streaming.
		out.append("[indent][code][color=#%s]%s[/color][/code][/indent]" % [code_hex, escape_bbcode("\n".join(fence))])
	return "\n".join(out)


## Plain text of a message `content` (string or content-block array).
static func content_text(content) -> String:
	if content is String:
		return content
	var parts := PackedStringArray()
	if content is Array:
		for block in content:
			if not (block is Dictionary):
				continue
			match str(block.get("type", "")):
				"text":
					parts.append(str(block.get("text", "")))
				"image":
					parts.append("[image %s]" % str(block.get("mimeType", "")))
	return "\n".join(parts)


## One-line description of a tool call for card headers.
static func tool_summary(tool_name: String, args) -> String:
	if not (args is Dictionary):
		return ""
	for key in ["command", "path", "file_path", "pattern", "query", "url"]:
		if args.has(key):
			var v := str(args[key]).replace("\n", " ⏎ ")
			return v.left(120) + ("…" if v.length() > 120 else "")
	var s := JSON.stringify(args)
	return s.left(100) + ("…" if s.length() > 100 else "")


static func format_tokens(n: float) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (n / 1_000_000.0)
	if n >= 1000:
		return "%.1fk" % (n / 1000.0)
	return str(int(n))
