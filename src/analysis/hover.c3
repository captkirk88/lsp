module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

fn void encode_hover(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	while (true)
	{
		if (try tok = lex.next())
		{
			usz tok_end = tok.offset + tok.len;
			if (tok.offset <= offset && offset < tok_end)
			{
				// For identifiers, try to find the declaration and extract doc comments
				TokenType ct = tok.type;
				if (ct == IDENT || ct == TYPE_IDENT || ct == CONST_IDENT)
				{
					DString doc = dstring::temp();

					// Detect method call context for hover
					if (ct == IDENT)
					{
						TokenList hover_tokens;
						hover_tokens.init(mem);
						tokenize_content(content, &hover_tokens);
						Token hover_tok;
						usz hover_idx;
						if (find_token_at(&hover_tokens, offset, &hover_tok, &hover_idx))
						{
							if (hover_idx >= 2 &&
								hover_tokens.entries[hover_idx - 1].type == DOT &&
								hover_tokens.entries[hover_idx - 2].type == IDENT)
							{
								String receiver_name = hover_tokens.entries[hover_idx - 2].text;
								String type_name = find_variable_type(&hover_tokens, receiver_name);
								if (type_name.len > 0)
								{
									// Try resolved alias first (e.g. List for TokenList)
									String resolved = resolve_type_alias_across(&hover_tokens, type_name, docs);
									if (resolved.len == 0)
									{
										String hover_file_path = uri_to_path(uri);
										if (hover_file_path.len > 0)
										{
											resolved = resolve_alias_in_project(hover_file_path, type_name);
										}
									}
									if (resolved.len > 0 && resolved != type_name)
									{
										find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, resolved);
									}
									// Try direct type if alias didn't find it
									if (doc.str_view().len == 0)
									{
										find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, type_name);
									}
								}
							}
						}
						hover_tokens.free();
					}

					// Regular (non-method) hover if method resolution didn't find anything
					if (doc.str_view().len == 0)
					{
						find_hover_docs(uri, content, tok, docs, stdlib_path, &doc);
					}

					if (doc.str_view().len > 0)
					{
						usz line = find_line(lo, tok.offset);
						usz start_char = tok.offset - lo.offsets[line];
						usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);
						usz end_char = tok_end - lo.offsets[end_line];

						out.append(`{"contents":{"kind":"markdown","value":"`);
						json_escape_into(out, doc.str_view());
						out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
						return;
					}
				}

				// Fallback to basic token description
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
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}

// Search for the declaration of a token and extract its doc comment + signature.
// Searches: current file -> open documents -> project files -> stdlib.
fn void find_hover_docs(String uri, String content, Token cursor_tok, DocumentList* docs, String stdlib_path, DString* out, String method_type = "") @private
{
	// If method type specified, try method-specific search first with each type candidate
	if (method_type.len > 0)
	{
		if (try_extract_docs_from(content, cursor_tok, out, method_type)) return;
		for (usz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, method_type)) return;
		}
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			if (scan_project_docs(file_path, cursor_tok, out, method_type)) return;
		}
		if (stdlib_path.len > 0)
		{
			if (scan_dir_docs(stdlib_path, cursor_tok, out, 0, method_type)) return;
		}
		return;
	}

	// 1. Current file
	if (try_extract_docs_from(content, cursor_tok, out)) return;

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out)) return;
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		if (scan_project_docs(file_path, cursor_tok, out)) return;
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		if (scan_dir_docs(stdlib_path, cursor_tok, out, 0)) return;
	}
}

// Tokenize content, find the declaration of target, and extract doc comment + signature.
fn bool try_extract_docs_from(String content, Token target, DString* out, String method_type = "") @private
{
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	usz decl_idx = find_decl_for_hover(&tokens, target, method_type);
	if (decl_idx >= tokens.size) return false;

	extract_docs_at(content, &tokens, decl_idx, out);
	return out.str_view().len > 0;
}

// Find the declaration index — similar to find_declaration but also checks same-name at cursor.
// When method_type is non-empty, searches for fn Type.name( pattern only.
fn usz find_decl_for_hover(TokenList* tokens, Token target, String method_type = "") @private
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (is_type_declaration_keyword(tokens.entries[i].type))
				{
					if (tokens.entries[i + 1].type == TYPE_IDENT && tokens.entries[i + 1].text == name)
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (tokens.entries[i].type == CONSTDEF && tokens.entries[i + 1].type == CONST_IDENT && tokens.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
		case IDENT:
			if (method_type.len > 0)
			{
				// Search for fn ... Type.method( pattern only
				for (usz i = 0; i < tokens.size; i++)
				{
					if (tokens.entries[i].type != FUNC) continue;
					for (usz j = i + 1; j < tokens.size && j < i + 64; j++)
					{
						if (tokens.entries[j].type == LPAREN)
						{
							if (j >= 3 &&
								tokens.entries[j - 1].type == IDENT && tokens.entries[j - 1].text == name &&
								tokens.entries[j - 2].type == DOT &&
								tokens.entries[j - 3].type == TYPE_IDENT && tokens.entries[j - 3].text == method_type)
							{
								return j - 1;
							}
							break;
						}
						if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
					}
				}
				return tokens.size;
			}
			// fn ... name(
			for (usz i = 0; i < tokens.size; i++)
			{
				if (tokens.entries[i].type != FUNC) continue;
				for (usz j = i + 1; j < tokens.size && j < i + 64; j++)
				{
					if (tokens.entries[j].type == LPAREN)
					{
						if (j > 0 && tokens.entries[j - 1].type == IDENT && tokens.entries[j - 1].text == name)
						{
							return j - 1;
						}
						break;
					}
					if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
				}
			}
			// macro name
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (tokens.entries[i].type == MACRO && tokens.entries[i + 1].type == IDENT && tokens.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
		default:
			return tokens.size;
	}

	return tokens.size;
}

// Extract doc comment and signature from the declaration site.
fn void extract_docs_at(String content, TokenList* tokens, usz decl_idx, DString* out) @private
{
	// Find the start of the declaration (fn, struct, macro, constdef, etc.)
	usz decl_start_idx = decl_idx;
	if (decl_idx > 0)
	{
		// Walk back to find the keyword that starts this declaration
		for (usz i = decl_idx; i > 0; i--)
		{
			TokenType t = tokens.entries[i - 1].type;
			if (t == FUNC || t == MACRO || t == STRUCT || t == UNION || t == ENUM || t == BITSTRUCT || t == INTERFACE || t == FAULTDEF || t == CONSTDEF || t == TYPEDEF || t == ALIAS || t == ATTRDEF)
			{
				decl_start_idx = i - 1;
				break;
			}
			// Don't walk back past other declarations or braces
			if (t == RBRACE || t == EOS || t == LBRACE) break;
		}
	}

	// Extract the signature line from source
	usz sig_start = tokens.entries[decl_start_idx].offset;
	// Find the end: up to '{' or ';' or end of token stream
	usz sig_end = sig_start;
	for (usz i = decl_start_idx; i < tokens.size; i++)
	{
		if (tokens.entries[i].type == LBRACE || tokens.entries[i].type == EOS)
		{
			sig_end = tokens.entries[i].offset;
			break;
		}
		sig_end = tokens.entries[i].offset + tokens.entries[i].len;
	}
	// Trim trailing whitespace
	while (sig_end > sig_start && (content[sig_end - 1] == ' ' || content[sig_end - 1] == '\t' || content[sig_end - 1] == '\n' || content[sig_end - 1] == '\r'))
	{
		sig_end--;
	}
	String signature = content[sig_start:sig_end - sig_start];

	// Extract doc comments above the declaration
	DString comment = dstring::temp();
	if (decl_start_idx > 0)
	{
		// Collect comment tokens immediately before the declaration
		usz first_comment = decl_start_idx;
		for (usz i = decl_start_idx; i > 0; i--)
		{
			TokenType t = tokens.entries[i - 1].type;
			if (t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT)
			{
				first_comment = i - 1;
			}
			else
			{
				break;
			}
		}

		for (usz i = first_comment; i < decl_start_idx; i++)
		{
			if (tokens.entries[i].type == LINE_COMMENT || tokens.entries[i].type == BLOCK_COMMENT || tokens.entries[i].type == CONTRACT)
			{
				String text = content[tokens.entries[i].offset:tokens.entries[i].len];
				String cleaned = strip_comment_markers(text);
				if (cleaned.len > 0)
				{
					if (comment.str_view().len > 0) comment.append("\n");
					comment.append(cleaned);
				}
			}
		}
	}

	// Build the hover content
	out.append("```c3\n");
	out.append(signature);
	out.append("\n```");

	if (comment.str_view().len > 0)
	{
		out.append("\n\n---\n\n");
		out.append(comment.str_view());
	}
}

// Strip comment markers (// or /* ... */) from a comment string.
fn String strip_comment_markers(String text) @private
{
	if (text.len >= 2 && text[0] == '/' && text[1] == '/')
	{
		String rest = text[2..];
		// Strip leading space
		if (rest.len > 0 && rest[0] == ' ') rest = rest[1..];
		// Trim trailing newline
		while (rest.len > 0 && (rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	if (text.len >= 4 && text[0] == '/' && text[1] == '*')
	{
		// Remove /* and */
		String rest = text[2..];
		if (rest.len >= 2 && rest[rest.len - 2] == '*' && rest[rest.len - 1] == '/')
		{
			rest = rest[:rest.len - 2]; // Remove trailing */
		}
		// Trim whitespace
		while (rest.len > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r'))
		{
			rest = rest[1..];
		}
		while (rest.len > 0 && (rest[rest.len - 1] == ' ' || rest[rest.len - 1] == '\t' || rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	// Contract/doc comment: <* ... *>
	if (text.len >= 4 && text[0] == '<' && text[1] == '*')
	{
		// Remove <* and *>
		String rest = text[2..];
		if (rest.len >= 2 && rest[rest.len - 2] == '*' && rest[rest.len - 1] == '>')
		{
			rest = rest[:rest.len - 2];
		}
		// Trim leading/trailing whitespace
		while (rest.len > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r'))
		{
			rest = rest[1..];
		}
		while (rest.len > 0 && (rest[rest.len - 1] == ' ' || rest[rest.len - 1] == '\t' || rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	return text;
}

// Scan project dirs for hover docs (mirrors scan_project_files pattern).
fn bool scan_project_docs(String file_path, Token target, DString* out, String method_type = "") @private
{
	String dir = parent_dir(file_path);
	String project_root = "";
	String check_dir = dir;
	char[]? project_json_data;
	for (int depth = 0; depth < 10; depth++)
	{
		if (check_dir.len == 0 || check_dir == "/") break;
		DString pj = dstring::temp();
		pj.appendf("%s/project.json", check_dir);
		if (try data = file::load(mem, pj.str_view()))
		{
			project_root = check_dir;
			project_json_data = data;
			break;
		}
		check_dir = parent_dir(check_dir);
	}

	if (project_root.len == 0) return false;

	const int MAX_SEARCH_DIRS = 32;
	String[MAX_SEARCH_DIRS] search_dirs;
	usz search_count = 0;

	if (try data = project_json_data)
	{
		defer mem::free(data);
		if (try pjson = json::tparse_string((String)data))
		{
			if (try deps = pjson.get("dependency-search-paths"))
			{
				usz deps_len = deps.get_len();
				for (usz i = 0; i < deps_len && search_count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string()) search_dirs[search_count++] = item.s;
				}
			}
			if (try srcs = pjson.get("sources"))
			{
				usz srcs_len = srcs.get_len();
				for (usz i = 0; i < srcs_len && search_count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (item.is_string())
					{
						String src = item.s;
						usz dir_end = src.len;
						for (usz j = 0; j < src.len; j++)
						{
							if (src[j] == '*')
							{
								dir_end = j;
								break;
							}
						}
						if (dir_end > 0 && src[dir_end - 1] == '/') dir_end--;
						if (dir_end > 0)
						{
							String src_dir = src[:dir_end];
							bool dup = false;
							for (usz k = 0; k < search_count; k++)
							{
								if (search_dirs[k] == src_dir)
								{
									dup = true;
									break;
								}
							}
							if (!dup) search_dirs[search_count++] = src_dir;
						}
					}
				}
			}
		}
	}

	if (search_count == 0)
	{
		search_dirs[0] = "src";
		search_dirs[1] = "lib";
		search_count = 2;
	}

	for (usz i = 0; i < search_count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", project_root, search_dirs[i]);
		if (scan_dir_docs(search_path.str_view(), target, out, 0, method_type)) return true;
	}
	return false;
}

fn bool scan_dir_docs(String dir_path, Token target, DString* out, int depth, String method_type = "") @private
{
	if (depth > MAX_SCAN_DEPTH) return false;

	Path p;
	if (try pp = path::temp(dir_path))
	{
		p = pp;
	}
	else
	{
		return false;
	}
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		return false;
	}
	defer
	{
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries)
	{
		String entry_name = entry.str_view();
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			if (try file_content = file::load(mem, full_path))
			{
				defer mem::free(file_content);
				if (try_extract_docs_from((String)file_content, target, out, method_type)) return true;
			}
		}
		else
		{
			if (scan_dir_docs(full_path, target, out, depth + 1, method_type)) return true;
		}
	}
	return false;
}
