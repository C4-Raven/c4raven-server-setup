"""Stop clients forging X-Ssl-Cert through nginx blocks that do not verify certs.

    python3 nginx_clear_ssl_cert.py FILE [FILE ...]

Raven trusts the X-Ssl-Cert header as "this client presented a verified
certificate". Only the mTLS listeners (443/8443 in raven_https) set it, from
$ssl_client_escaped_cert. Any other server block that proxies to the backend
must clear it, or a client can simply send the header itself. The shipped
templates (raven_http, raven_certificate_enrollment[_domain]) now do; this
brings an existing install's copies -- possibly edited by certbot or the
admin, so not simply replaceable -- into line, in place.

For every `location { ... }` that proxies to 127.0.0.1:8081 and does not
mention X-Ssl-Cert at all, adds `proxy_set_header X-Ssl-Cert "";` just
before its closing brace, at the indentation of its proxy_pass. Idempotent:
a second run changes nothing. A location with nested blocks is left alone.
Prints one line per file; exit 0 on success (changed or not), 2 when a file
cannot be read or written.

Used by update.sh here and by c4raven-updater's update.sh.
"""

import os
import re
import sys


def patch(text):
    inserts = []
    for m in re.finditer(r"location[^{;]*\{", text):
        start = m.end()
        end = text.find("}", start)
        if end < 0:
            break
        body = text[start:end]
        if "{" in body or "127.0.0.1:8081" not in body or "X-Ssl-Cert" in body:
            continue
        indent = re.search(r"\n([ \t]+)proxy_pass", body)
        indent = indent.group(1) if indent else "        "
        inserts.append((end, f'{indent}proxy_set_header X-Ssl-Cert "";\n'))
    for pos, line in reversed(inserts):
        line_start = text.rfind("\n", 0, pos) + 1
        text = text[:line_start] + line + text[line_start:]
    return text, len(inserts)


def main(paths):
    rc = 0
    for path in map(os.path.realpath, paths):
        try:
            with open(path) as f:
                old = f.read()
            new, n = patch(old)
            if n:
                st = os.stat(path)
                tmp = path + ".c4raven-tmp"
                with open(tmp, "w") as f:
                    f.write(new)
                os.chmod(tmp, st.st_mode & 0o7777)
                os.replace(tmp, path)
            print(f"{path}: cleared X-Ssl-Cert in {n} location(s)")
        except OSError as e:
            print(f"{path}: {e}", file=sys.stderr)
            rc = 2
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
