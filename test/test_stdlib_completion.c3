module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::os::process;



fn String get_test_stdlib_path() {
	// 1. Run "where c3c" (Windows) or "which c3c" (Unix/macOS)
	String[] cmd;
	$if env::WIN32:
		cmd = { "where.exe", "c3c" };
	$else
		cmd = { "which", "c3c" };
	$endif

	String c3c_path = "";
	Process proc;
	if (try p = process::spawn(cmd, STDERR_TO_STDOUT | INHERIT_ENV))
	{
		proc = p;
		if (catch proc.join())
		{
			proc.destroy();
		}
		else
		{
			char[2048] buf;
			sz n = proc.read_stdout(&buf[0], 2048) ?? 0;
			proc.destroy();
			if (n > 0)
			{
				String raw_path = (String)buf[:n];
				// Trim trailing newlines and spaces
				sz len = raw_path.len;
				while (len > 0)
				{
					char c = raw_path[len - 1];
					if (c == '\r' || c == '\n' || c == ' ' || c == '\t')
					{
						len--;
					}
					else
					{
						break;
					}
				}
				if (len > 0)
				{
					c3c_path = raw_path[..len - 1];
				}
			}
		}
	}

	if (c3c_path.len == 0)
	{
		builtin::panic("c3c executable not found", "", "", 0);
		return "";
	}

	// Normalize backslashes to forward slashes
	DString norm_c3c = dstring::temp();
	foreach (char c : c3c_path)
	{
		if (c == '\\')
		{
			norm_c3c.append_char('/');
		}
		else
		{
			norm_c3c.append_char(c);
		}
	}
	String compiler_path = norm_c3c.str_view();

	// Check if this is a scoop shim (has a .shim file)
	String parent = parent_dir(compiler_path);
	DString shim_path = dstring::temp();
	shim_path.appendf("%s/c3c.shim", parent);

	if (try shim_content = file::load(mem, shim_path.str_view()))
	{
		defer mem::free(shim_content);
		String content = (String)shim_content;
		if (try idx = content.index_of(`path = "`))
		{
			sz start = idx + 8;
			if (try end_quote = content[start..].index_of(`"`))
			{
				String real_path = content[start..start + end_quote - 1];
				DString norm_real = dstring::temp();
				foreach (char c : real_path)
				{
					if (c == '\\')
					{
						norm_real.append_char('/');
					}
					else
					{
						norm_real.append_char(c);
					}
				}
				compiler_path = norm_real.str_view();
				parent = parent_dir(compiler_path);
			}
		}
	}

	// Candidates for stdlib path
	String[6] candidates;
	DString c0 = dstring::temp(); c0.appendf("%s/lib/std", parent); candidates[0] = c0.str_view();
	DString c1 = dstring::temp(); c1.appendf("%s/../lib/std", parent); candidates[1] = c1.str_view();
	DString c2 = dstring::temp(); c2.appendf("%s/../lib/c3/std", parent); candidates[2] = c2.str_view();
	DString c3 = dstring::temp(); c3.appendf("%s/../share/c3/std", parent); candidates[3] = c3.str_view();
	candidates[4] = "/usr/lib/c3/std";
	candidates[5] = "/usr/local/lib/c3/std";

	foreach (c : candidates)
	{
		if (c.len == 0) continue;
		if (try pp = path::tnew(c))
		{
			if (try el = path::ls(mem, pp))
			{
				foreach (&e : el) e.free(mem);
				el.free();
				return c;
			}
		}
	}

	builtin::panic("Fill in with path to c3 std", "", "", 0);
	return "";
}

fn void test_stdlib_completion_import_std() @test {
	String stdlib_path = get_test_stdlib_path();
	if (stdlib_path.len == 0) {
		io::printfn("Warning: stdlib path not found, skipping test");
		return;
	}

	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Test importing std and asking for completions right after std::
	String content = "import std::";
	encode_completions("file:///main.c3", content, content.len, docs, stdlib_path, &out);
	String result = out.str_view();

	io::printfn("Result for std:: completion:\n%s", result);
	// It should contain labels like "io", "collections", "core", "math", etc.
	assert(result.contains(`"label":"io"`), "expected 'io' in completions");
	assert(result.contains(`"label":"collections"`), "expected 'collections' in completions");
}

fn void test_stdlib_completion_std_io_methods() @test {
	String stdlib_path = get_test_stdlib_path();
	if (stdlib_path.len == 0) {
		io::printfn("Warning: stdlib path not found, skipping test");
		return;
	}

	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Test completions for std::io::
	String content = "import std::io;\nfn void main() { std::io::";
	encode_completions("file:///main.c3", content, content.len, docs, stdlib_path, &out);
	String result = out.str_view();

	io::printfn("Result for std::io:: completion:\n%s", result);
	// It should contain functions in std::io like "print", "printf", "printfn", "sprintf", etc.
	assert(result.contains(`"label":"printfn"`), "expected 'printfn' in completions");
}
