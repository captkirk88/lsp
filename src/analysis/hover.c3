module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

fn void encode_hover(String content, usz offset, DString* out) {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	while (true) {
		if (try tok = lex.next()) {
			usz tok_end = tok.offset + tok.len;
			if (tok.offset <= offset && offset < tok_end) {
				String desc = get_token_description(tok.type, tok.text);
				if (desc.len == 0) return;

				usz line = find_line(lo, tok.offset);
				usz start_char = tok.offset - lo.offsets[line];
				usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);
				usz end_char = tok_end - lo.offsets[end_line];

				out.append(`{"contents":{"kind":"markdown","value":"`);
				json_escape_into(out, desc);
				out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
				return;
			}
			if (tok.offset > offset) return;
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}

