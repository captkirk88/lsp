module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const usz MAX_LINE_OFFSETS = 100000;

struct LineOffsets {
	usz[MAX_LINE_OFFSETS] offsets;
	usz count;
}

fn void build_line_offsets(String content, LineOffsets* lo) {
	lo.count = 1;
	lo.offsets[0] = 0; // Line 0 starts at byte 0

	for (usz i = 0; i < content.len && lo.count < MAX_LINE_OFFSETS; i++) {
		if (content[i] == '\n') {
			lo.offsets[lo.count] = i + 1;
			lo.count++;
		}
	}
}

fn usz find_line(LineOffsets* lo, usz offset) {
	usz low = 0;
	usz high = lo.count;
	while (low < high) {
		usz mid = (low + high) / 2;
		if (lo.offsets[mid] <= offset) {
			low = mid + 1;
		} else {
			high = mid;
		}
	}
	return low > 0 ? low - 1 : 0;
}

fn void encode_semantic_tokens(String content, DString* out) {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	usz prev_line = 0;
	usz prev_start_char = 0;
	bool first = true;

	while (true) {
		if (try tok = lex.next()) {
			SemanticCategory category = map_token_type(tok.type);
			if (category == SKIP) continue;

			usz tok_start = tok.offset;
			usz tok_end = tok.offset + tok.len;
			usz start_line = find_line(lo, tok_start);
			usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);

			if (start_line == end_line) {
				// Single-line token — emit directly
				usz start_char = tok_start - lo.offsets[start_line];
				usz delta_line = start_line - prev_line;
				usz delta_start_char = delta_line == 0 ? start_char - prev_start_char : start_char;

				if (!first) out.append_char(',');
				out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, tok.len, category.index);
				first = false;

				prev_line = start_line;
				prev_start_char = start_char;
			} else {
				// Multi-line token — split into one entry per line
				for (usz ln = start_line; ln <= end_line; ln++) {
					usz seg_start;
					usz seg_end;

					if (ln == start_line) {
						seg_start = tok_start;
					} else {
						seg_start = lo.offsets[ln];
					}

					if (ln == end_line) {
						seg_end = tok_end;
					} else {
						// End at the newline (or next line's offset)
						seg_end = ln + 1 < lo.count ? lo.offsets[ln + 1] : tok_end;
						// Don't include the newline character itself
						if (seg_end > seg_start && seg_end <= content.len && content[seg_end - 1] == '\n') {
							seg_end--;
						}
						if (seg_end > seg_start && seg_end <= content.len && content[seg_end - 1] == '\r') {
							seg_end--;
						}
					}

					if (seg_end <= seg_start) continue;

					usz seg_char = seg_start - lo.offsets[ln];
					usz seg_len = seg_end - seg_start;
					usz delta_line = ln - prev_line;
					usz delta_start_char = delta_line == 0 ? seg_char - prev_start_char : seg_char;

					if (!first) out.append_char(',');
					out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, seg_len, category.index);
					first = false;

					prev_line = ln;
					prev_start_char = seg_char;
				}
			}
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}
