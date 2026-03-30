module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const usz MAX_LOOKAHEAD = 64;
const usz MAX_SYMBOLS = 512;

struct SymbolEntry
{
	DocumentSymbol sym;
	String parent_type;  // For "Type.method", this is "Type"; empty otherwise
	bool is_child;
}

fn void encode_document_symbols(String content, DString* out)
{
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();
	LineOffsets* lo = stream.get_line_offsets();

	// Collect all symbols first
	SymbolEntry[MAX_SYMBOLS] entries;
	usz entry_count = 0;

	for (usz i = 0; i < stream.tokens.size; i++)
	{
		if (entry_count >= MAX_SYMBOLS) break;

		Token tok = stream.tokens.entries[i];
		String name = "";
		String parent_type = "";
		int kind = 0;
		usz name_offset = 0;
		usz name_len = 0;
		usz decl_offset = tok.offset;
		usz end_offset = 0;
		bool has_braces = false;

		switch (tok.type)
		{
			case MODULE:
				// module IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 2; // Module
					end_offset = stream.tokens.find_eos_end(i + 2);
				}
			case IMPORT:
				// import IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 2; // Module
					end_offset = stream.tokens.find_eos_end(i + 2);
				}
			case FUNC:
				// fn ... IDENT LPAREN — the IDENT before LPAREN is the name
				// If preceded by TYPE_IDENT DOT, it's a method
				usz lparen_idx = 0;
				for (usz j = i + 1; j < stream.tokens.size && j < i + MAX_LOOKAHEAD; j++)
				{
					if (stream.tokens.entries[j].type == LPAREN)
					{
						lparen_idx = j;
						break;
					}
					// Stop on LBRACE/EOS (malformed)
					if (stream.tokens.entries[j].type == LBRACE || stream.tokens.entries[j].type == EOS) break;
				}
				if (lparen_idx > 0 && lparen_idx > i + 1)
				{
					Token fn_name = stream.tokens.entries[lparen_idx - 1];
					if (is_ident(fn_name.type))
					{
						// Check for Type.method pattern
						if (lparen_idx >= 3 + i && stream.tokens.entries[lparen_idx - 2].type == DOT && stream.tokens.entries[lparen_idx - 3].type == TYPE_IDENT)
						{
							parent_type = stream.tokens.entries[lparen_idx - 3].text;
							name = fn_name.text;
							name_offset = fn_name.offset;
							name_len = fn_name.len;
							decl_offset = stream.tokens.entries[lparen_idx - 3].offset;
						}
						else
						{
							name = fn_name.text;
							name_offset = fn_name.offset;
							name_len = fn_name.len;
						}
						kind = 6; // Method for all functions, will be nested if has parent
						has_braces = true;
					}
				}
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				// struct/union/bitstruct TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 23; // Struct
					has_braces = true;
				}
			case ENUM:
			case FAULTDEF:
				// enum/faultdef TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 10; // Enum
					has_braces = true;
				}
			case INTERFACE:
				// interface TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 11; // Interface
					has_braces = true;
				}
			case MACRO:
				// macro IDENT or macro TYPE_IDENT
				if (i + 1 < stream.tokens.size)
				{
					Token nt = stream.tokens.entries[i + 1];
					if (is_ident(nt.type) || nt.type == TYPE_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 12; // Function
						has_braces = true;
					}
				}
			case CONSTDEF:
			case TYPEDEF:
			case ALIAS:
				if (i + 1 < stream.tokens.size)
				{
					Token nt = stream.tokens.entries[i + 1];
					if (nt.type == TYPE_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 26; // TypeParameter
					}
					else if (nt.type == CONST_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 14; // Constant
					}
					if (kind != 0)
					{
						end_offset = stream.tokens.find_eos_end(i + 2);
					}
				}
			default:
				continue;
		}

		if (name.len == 0 || kind == 0) continue;

		// Find end of declaration for braced declarations
		if (has_braces && end_offset == 0)
		{
			end_offset = stream.tokens.find_brace_end(i + 1);
		}
		if (end_offset == 0)
		{
			end_offset = name_offset + name_len;
		}

		// Build range and selectionRange using line offsets
		usz decl_line = lo.find_line(decl_offset);
		usz decl_char = decl_offset - lo.entries[decl_line];
		usz end_line = lo.find_line(end_offset > 0 ? end_offset - 1 : 0);
		usz end_char = (end_offset > 0 ? end_offset : 1) - lo.entries[end_line];

		usz sel_line = lo.find_line(name_offset);
		usz sel_char = name_offset - lo.entries[sel_line];
		usz sel_end_line = sel_line;
		usz sel_end_char = sel_char + name_len;

		entries[entry_count] = {
			.sym = {
				.name = name,
				.kind = kind,
				.range = {
					.start = {.line = decl_line, .character = decl_char},
					.end = {.line = end_line, .character = end_char},
				},
				.selection_range = {
					.start = {.line = sel_line, .character = sel_char},
					.end = {.line = sel_end_line, .character = sel_end_char},
				},
			},
			.parent_type = parent_type,
		};
		entry_count++;
	}

	// Second pass: nest methods under their parent type symbols
	// Flat pool for all children across all parents
	DocumentSymbol[MAX_SYMBOLS] children_pool;
	usz pool_used = 0;

	for (usz i = 0; i < entry_count; i++)
	{
		int k = entries[i].sym.kind;
		// Only types can have children (struct, enum, interface)
		if (k != 23 && k != 10 && k != 11) continue;
		String type_name = entries[i].sym.name;

		usz start = pool_used;
		for (usz j = 0; j < entry_count; j++)
		{
			if (pool_used >= MAX_SYMBOLS) break;
			if (entries[j].parent_type.len > 0 && entries[j].parent_type == type_name)
			{
				children_pool[pool_used] = entries[j].sym;
				pool_used++;
				entries[j].is_child = true;
			}
		}

		if (pool_used > start)
		{
			entries[i].sym.children = children_pool[start..pool_used - 1];
		}
	}

	// Encode: output top-level symbols only
	bool first = true;
	for (usz i = 0; i < entry_count; i++)
	{
		if (entries[i].is_child) continue;

		if (entries[i].sym.kind == 6)
		{
			if (entries[i].parent_type.len > 0)
			{
				// Orphan method (no matching struct in this file) — show as Type.method
				DString combined = dstring::temp();
				combined.append(entries[i].parent_type);
				combined.append_char('.');
				combined.append(entries[i].sym.name);
				entries[i].sym.name = combined.str_view();
			}
			entries[i].sym.kind = 12; // Function
		}

		if (!first) out.append_char(',');
		entries[i].sym.encode(out);
		first = false;
	}
}

fn usz TokenList.find_eos_end(&self, usz start)
{
	for (usz j = start; j < self.size; j++)
	{
		if (self.entries[j].type == EOS)
		{
			return self.entries[j].offset + self.entries[j].len;
		}
	}
	return 0;
}

fn usz TokenList.find_brace_end(&self, usz start)
{
	usz depth = 0;
	bool found_brace = false;
	for (usz j = start; j < self.size; j++)
	{
		if (self.entries[j].type == LBRACE)
		{
			depth++;
			found_brace = true;
		}
		else if (self.entries[j].type == RBRACE)
		{
			if (depth > 0) depth--;
			if (depth == 0 && found_brace)
			{
				return self.entries[j].offset + self.entries[j].len;
			}
		}
	}
	return 0;
}
