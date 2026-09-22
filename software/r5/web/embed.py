"""Embed the self-contained web UI without external runtime assets."""
import json
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text('static const char web_page[] =\n' +
    '\n'.join(json.dumps(line, ensure_ascii=True) for line in source.splitlines(keepends=True)) + ';\n')
