#!/usr/bin/python3
"""Comment out Enterprise Linux's stock default_server block in nginx.conf.

Why this exists
---------------
EL's nginx ships a `server { listen 80; ... root /usr/share/nginx/html; }`
block *inline* in /etc/nginx/nginx.conf. Debian's does not -- its default site
is a file in sites-enabled that the postinst simply never enables. Left in
place on EL it is a second server on port 80 competing with raven_http.conf for
the implicit default_server, so the port-80 -> HTTPS redirect depends on
nginx.conf's include ordering rather than on anything we control.

Why it is a program and not a sed/grep
--------------------------------------
Locating that block means parsing nginx's configuration grammar, and the
previous attempt did it with string search:

    hit   = src.find('/usr/share/nginx/html')
    start = src.rfind('server', 0, hit)      # <-- bug

`rfind('server', ...)` does not find the `server` *keyword*. In the real stock
file the nearest preceding occurrence of the substring is inside

    server_name  _;

on the line above `root`, so `start` landed mid-statement, `src.index('{',
start)` then found the brace of `location = /404.html {`, and the brace matcher
commented out that location block instead of the server block. The result was a
still-live `server { listen 80; }` with its `root` and `server_name` commented
out -- and, because the "already done" marker had been written, a setup run
that never retried.

So: a real (small) nginx-grammar parser, comment- and quote-aware, plus a
post-condition that re-parses the result and refuses to write a file in which
the block is still live. That post-condition alone would have caught the bug.

Usage
-----
    nginx_default_server.py --check   /etc/nginx/nginx.conf
    nginx_default_server.py --disable /etc/nginx/nginx.conf [--backup-suffix .c4raven.bak]

Exit codes
----------
    0   --check: a live stock default server is present
        --disable: it was found and commented out
    10  nothing to do (no live stock default server, or already disabled)
    1   error
"""

import argparse
import os
import shutil
import sys

MARKER = "# c4raven: stock default_server disabled (raven_http.conf owns port 80)"
DEFAULT_DOCROOT = "/usr/share/nginx/html"

# nginx's own set of statement terminators / block delimiters.
_SPACE = " \t\r\n\f\v"


class Directive(object):
    """One nginx directive. `children is None` for a simple `name args;`."""

    __slots__ = ("name", "args", "start", "end", "children", "parent")

    def __init__(self, name, args, start, parent):
        self.name = name
        self.args = args
        self.start = start      # index of the first character of the directive
        self.end = None         # index just past its ';' or its closing '}'
        self.children = None    # list for a block, None for a simple directive
        self.parent = parent

    @property
    def is_block(self):
        return self.children is not None

    def path(self):
        """('http', 'server') for a server block inside http.

        Inclusive of this directive, which is what every caller compares
        against. Starting the walk at self.parent instead returns the
        *ancestor* path ('http',), and find_default_server()'s
        `path() != ("http", "server")` guard then rejects every real server
        block -- the tool reports "nothing to do" on a stock nginx.conf and
        the default_server stays live. That is the same silent no-op the
        rfind() bug produced, so there is a regression test for it.
        """
        names = []
        node = self
        while node is not None and node.name is not None:
            names.append(node.name)
            node = node.parent
        return tuple(reversed(names))

    def __repr__(self):
        return "<Directive %s %r [%s:%s]>" % (self.name, self.args, self.start, self.end)


class NginxSyntaxError(ValueError):
    pass


def parse(src):
    """Parse nginx configuration text into a synthetic root Directive.

    Comment-aware (`#` to end of line) and quote-aware (single and double, with
    backslash escapes), because every one of those is a place a naive substring
    search goes wrong.
    """
    root = Directive(None, [], 0, None)
    root.children = []
    root.end = len(src)

    stack = [root]
    tokens = []          # tokens of the statement being read
    tok = []             # characters of the token being read
    tok_quoted = False   # a quoted token is a token even when empty
    start = None         # index of the first character of the statement

    i = 0
    n = len(src)
    while i < n:
        c = src[i]

        if c == "#" and not tok and not tok_quoted:
            # Comment: runs to end of line. Never part of a token, and never
            # a place a directive name can be found.
            nl = src.find("\n", i)
            i = n if nl == -1 else nl + 1
            continue

        if c in "\"'":
            quote = c
            i += 1
            if start is None:
                start = i - 1
            while i < n and src[i] != quote:
                if src[i] == "\\" and i + 1 < n:
                    tok.append(src[i + 1])
                    i += 2
                    continue
                tok.append(src[i])
                i += 1
            if i >= n:
                raise NginxSyntaxError("unterminated %s quote" % quote)
            i += 1  # past the closing quote
            tok_quoted = True
            continue

        if c in _SPACE:
            if tok or tok_quoted:
                tokens.append("".join(tok))
                tok = []
                tok_quoted = False
            i += 1
            continue

        if c == ";":
            if tok or tok_quoted:
                tokens.append("".join(tok))
                tok = []
                tok_quoted = False
            if tokens:
                d = Directive(tokens[0], tokens[1:], start, stack[-1])
                d.end = i + 1
                stack[-1].children.append(d)
            tokens = []
            start = None
            i += 1
            continue

        if c == "{":
            if tok or tok_quoted:
                tokens.append("".join(tok))
                tok = []
                tok_quoted = False
            name = tokens[0] if tokens else ""
            d = Directive(name, tokens[1:], start if start is not None else i, stack[-1])
            d.children = []
            stack[-1].children.append(d)
            stack.append(d)
            tokens = []
            start = None
            i += 1
            continue

        if c == "}":
            if tok or tok_quoted or tokens:
                raise NginxSyntaxError("unexpected '}' at offset %d" % i)
            if len(stack) == 1:
                raise NginxSyntaxError("unbalanced '}' at offset %d" % i)
            closed = stack.pop()
            closed.end = i + 1
            start = None
            i += 1
            continue

        if start is None:
            start = i
        tok.append(c)
        i += 1

    if len(stack) != 1:
        raise NginxSyntaxError("unbalanced '{' -- %d block(s) left open" % (len(stack) - 1))
    return root


def walk(node):
    if node.children:
        for child in node.children:
            yield child
            for sub in walk(child):
                yield sub


def find_default_server(src, docroot=DEFAULT_DOCROOT):
    """The live `http { server { ... root <docroot>; ... } }` block, or None.

    Only a *parsed* `root` directive counts, so neither the commented-out TLS
    server block in the stock file nor a `server_name` substring can be
    mistaken for one.
    """
    want = docroot.rstrip("/")
    for node in walk(parse(src)):
        if node.name != "server" or not node.is_block:
            continue
        if node.path() != ("http", "server"):
            continue
        for child in node.children:
            if child.name == "root" and child.args and child.args[0].rstrip("/") == want:
                return node
    return None


def comment_out(src, block, marker=MARKER):
    """Comment out `block`, preserving its indentation, prefixed by `marker`."""
    line_start = src.rfind("\n", 0, block.start) + 1
    indent = src[line_start:block.start]
    if indent.strip():
        # Something else shares the line; don't swallow it.
        line_start = block.start
        indent = ""
    body = src[line_start:block.end]
    commented = "\n".join("#" + line for line in body.split("\n"))
    return src[:line_start] + indent + marker + "\n" + commented + src[block.end:]


def disable(src, docroot=DEFAULT_DOCROOT, marker=MARKER):
    """Return (new_text, changed). Raises if the result is still wrong.

    The post-condition is the point: re-parse what we are about to write and
    insist the block really is gone. The `rfind('server')` bug produced a file
    that still had a live `server { listen 80; }` (with only its inner lines
    commented) and this check fails on it.
    """
    if marker in src:
        return src, False
    block = find_default_server(src, docroot)
    if block is None:
        return src, False

    out = comment_out(src, block, marker)

    still = find_default_server(out, docroot)
    if still is not None:
        raise AssertionError(
            "refusing to write: a live default server with root %s survives at "
            "offset %d -- the block locator matched the wrong range" % (docroot, still.start)
        )
    # Re-parsing already proves the braces balance; this makes the intent loud.
    parse(out)
    return out, True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true",
                      help="exit 0 if a live stock default server is present, 10 if not")
    mode.add_argument("--disable", action="store_true",
                      help="comment it out in place")
    ap.add_argument("path")
    ap.add_argument("--docroot", default=DEFAULT_DOCROOT)
    ap.add_argument("--backup-suffix", default="",
                    help="with --disable, copy the original to <path><suffix> first")
    args = ap.parse_args(argv)

    try:
        with open(args.path) as fh:
            src = fh.read()
    except OSError as exc:
        sys.stderr.write("cannot read %s: %s\n" % (args.path, exc))
        return 1

    try:
        if args.check:
            if MARKER in src:
                return 10
            return 0 if find_default_server(src, args.docroot) is not None else 10

        out, changed = disable(src, args.docroot)
    except (NginxSyntaxError, AssertionError) as exc:
        sys.stderr.write("%s: %s\n" % (args.path, exc))
        return 1

    if not changed:
        return 10

    if args.backup_suffix:
        shutil.copy2(args.path, args.path + args.backup_suffix)
    # Write via a temporary file in the same directory, then rename: a config
    # file nginx may be reloading is never half-written.
    tmp = args.path + ".c4raven.tmp"
    with open(tmp, "w") as fh:
        fh.write(out)
    shutil.copymode(args.path, tmp)
    os.replace(tmp, args.path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
