#!/usr/bin/env python3
"""claude-desk server: one web page per hub project, rendered from the project's DESK.md.

Loopback only; remote access goes through Tailscale Serve (claude-desk --remote on), which proxies
tailnet requests into this port and stamps them with the caller's login. Such a request (any request
that did not come straight from this machine's browser) is served only if that login is this
node's own user, so a public Funnel or a shared node gets 403. Dictation is transcribed here with faster-whisper (nothing leaves the machine);
the browser only records. Every mutating request must carry the X-Desk header (a cross-origin page
cannot set it, so a form on some website cannot drive this server). Commands and paths are
executed only if they appear literally in the project's DESK.md at request time; the browser
never supplies what to run.
"""
import glob, json, os, re, subprocess, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import markdown
import numpy as np

HOME = os.path.expanduser('~')
STATE = f'{HOME}/.local/state/claude-tabs'
HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get('CLAUDE_DESK_PORT', 7357))
DOC = 'DESK.md'
CHAT_TAIL = 14
STT_MODEL = os.environ.get('CLAUDE_DESK_STT_MODEL', 'large-v3-turbo')

TEMPLATE = """# {name}

One line: what is running, finished or blocked right now.

## Now
- The question this project is answering this week, and where (sweep, probe, branch).
- Three to five bullets at most.

## State (date)
| item | value |
|---|---|
| latest result, read from the result file | number |

- [Open results](open:results)
- [Missing cells](<run:echo "run: waits for the command and shows its output">)
- [Viewer](<launch:xdg-open .>)

## Waiting on you
- Decisions only the user can make, with the size or cost of each.

## Buttons
- [Git status](<run:git status --short>)

```run
echo "fenced blocks tagged run get a play button"
```
"""


def tmux(*args, **kw):
    sock = os.environ.get('CLAUDE_TABS_SOCKET')
    cmd = ['tmux'] + (['-L', sock] if sock else []) + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def slug(path):
    return re.sub(r'[^A-Za-z0-9]', '-', path)


def projects():
    out = []
    for f in sorted(os.listdir(STATE)):
        if not f.endswith('.path'):
            continue
        path = open(f'{STATE}/{f}').read().strip()
        s = f[:-5]
        out.append({'slug': s, 'name': os.path.basename(path), 'path': path, 'tabs': tabs(s)})
    order = open(f'{STATE}/order').read().splitlines() if os.path.exists(f'{STATE}/order') else []   # as in the hub's top row
    out.sort(key=lambda p: (order.index(p['path']) if p['path'] in order else len(order), p['name']))
    return out


def project(s):
    path = open(f'{STATE}/{s}.path').read().strip()
    assert slug(path) == s, (path, s)
    return path


def tabs(s):
    """Tabs of a project: the hub's windows joined with the state file (tab key -> session id)."""
    sids = {}
    for line in open(f'{STATE}/{s}'):
        key, sid, name = line.rstrip('\n').split('\t')
        sids[key] = (sid, name)
    r = tmux('list-windows', '-t', f'=cc{s}', '-F', '#{window_index}\t#{window_id}\t#{@tabkey}\t#{pane_title}')
    out = []
    for line in r.stdout.splitlines():
        idx, wid, key, title = line.split('\t')
        sid, name = sids.get(key, (None, ''))
        out.append({'index': int(idx), 'id': wid, 'sid': sid, 'name': name, 'title': title})
    return out


def doc_path(s):
    return os.path.join(project(s), DOC)


def read_doc(s):
    p = doc_path(s)
    if not os.path.exists(p):
        with open(p, 'w') as f:
            f.write(TEMPLATE.format(name=os.path.basename(project(s)), doc=DOC))
    md = open(p).read()
    html = markdown.markdown(md, extensions=['fenced_code', 'tables', 'sane_lists'])
    return {'path': p, 'mtime': str(os.stat(p).st_mtime_ns), 'md': md, 'html': html}   # str: ns do not fit a JS number


def chat(s, sid):
    """Last user/assistant turns of a transcript: text blocks only, tool uses counted."""
    p = f'{HOME}/.claude/projects/{s}/{sid}.jsonl'
    if not os.path.exists(p):
        return []
    msgs = []
    for line in open(p):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get('type') not in ('user', 'assistant'):
            continue
        c = d['message']['content']
        blocks = [{'type': 'text', 'text': c}] if isinstance(c, str) else c
        text = '\n\n'.join(b['text'] for b in blocks if b.get('type') == 'text')
        tools = sum(b.get('type') == 'tool_use' for b in blocks)
        if text.startswith('<') and d['type'] == 'user':   # system-injected caveats, hook output
            text = re.sub(r'<[^>]+>.*?</[^>]+>', '', text, flags=re.S).strip()
        if not text and not tools:
            continue
        if msgs and msgs[-1]['role'] == d['type'] and d['type'] == 'assistant':
            msgs[-1]['text'] = (msgs[-1]['text'] + '\n\n' + text).strip()
            msgs[-1]['tools'] += tools
        else:
            msgs.append({'role': d['type'], 'text': text, 'tools': tools, 'time': d.get('timestamp')})
    return msgs[-CHAT_TAIL:]


PUBLISHED = re.compile(r'Published \S+ at (https://claude\.ai/\S*?artifact/[\w-]+) \(Version (\d+)\)')
_art_cache = {}   # transcript path -> (mtime, entries)


def scan_artifacts(path):
    """Artifact publishes in one transcript: Artifact tool calls joined with their results."""
    calls, found, byurl = {}, {}, {}   # found: by input url or file path; byurl: every URL form seen
    for line in open(path):
        if 'Artifact' not in line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get('type') not in ('user', 'assistant') or isinstance(d['message']['content'], str):
            continue
        for b in d['message']['content']:
            if b.get('type') == 'tool_use' and b.get('name') == 'Artifact' and b['input'].get('action', 'publish') == 'publish':
                calls[b['id']] = b['input']
            elif b.get('type') == 'tool_result' and b.get('tool_use_id') in calls:
                c = b['content']
                m = PUBLISHED.search(c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c if isinstance(x, dict)))
                if not m:
                    continue
                inp, url = calls[b['tool_use_id']], m.group(1)
                key = inp.get('url') or inp.get('file_path') or url   # same path in one conversation = same artifact
                e = byurl.get(inp.get('url')) or found.get(key)
                if e is None:
                    e = {'title': os.path.splitext(os.path.basename(inp.get('file_path', '')))[0] or 'artifact'}
                found[key] = byurl[url] = e
                if inp.get('title'):
                    e['title'] = inp['title']
                e.update(url=url, version=max(e.get('version', 0), int(m.group(2))), time=d.get('timestamp'))
    return list({id(e): e for e in found.values()}.values())


def artifacts(s):
    """Everything the project's tabs ever published, newest first, from the transcripts on disk."""
    names = {}
    for line in open(f'{STATE}/{s}'):
        key, sid, name = line.rstrip('\n').split('\t')
        names[sid] = name
    out = []
    for path in glob.glob(f'{HOME}/.claude/projects/{s}/*.jsonl'):
        mtime = os.stat(path).st_mtime_ns
        if path not in _art_cache or _art_cache[path][0] != mtime:
            _art_cache[path] = (mtime, scan_artifacts(path))
        sid = os.path.basename(path)[:-6]
        out += [dict(e, tab=names.get(sid, '')) for e in _art_cache[path][1]]
    return sorted(out, key=lambda e: e['time'] or '', reverse=True)


def send_text(s, wid, text):
    """Paste text into the tab's Claude prompt (bracketed paste keeps newlines) and press Enter."""
    target = f'=cc{s}:{wid}'
    tmux('load-buffer', '-b', 'desk', '-', input=text)
    r = tmux('paste-buffer', '-d', '-p', '-b', 'desk', '-t', target)
    assert r.returncode == 0, r.stderr
    time.sleep(0.4)
    tmux('send-keys', '-t', target, 'Enter')
    time.sleep(0.3)
    return tmux('capture-pane', '-p', '-t', target).stdout.rstrip()


_stt, _stt_lock = None, threading.Lock()


def stt():
    """faster-whisper, loaded on first use; GPU when CTranslate2 sees one, else CPU int8."""
    global _stt
    with _stt_lock:
        if _stt is None:
            import ctranslate2
            from faster_whisper import WhisperModel
            cuda = ctranslate2.get_cuda_device_count() > 0
            _stt = WhisperModel(STT_MODEL, device='cuda' if cuda else 'cpu', compute_type='float16' if cuda else 'int8')
            print(f'stt: {STT_MODEL} on {"cuda" if cuda else "cpu"}', flush=True)
    return _stt


def transcribe(pcm, lang):
    """pcm: int16 mono 16 kHz. Returns the text, '' when Whisper's VAD finds no speech."""
    audio = np.frombuffer(pcm, np.int16).astype(np.float32) / 32768
    model = stt()
    with _stt_lock:
        segs, _ = model.transcribe(audio, language=lang or None, beam_size=1, vad_filter=True,
                                   condition_on_previous_text=False)
        return ' '.join(x.text.strip() for x in segs).strip()


def in_doc(s, needle):
    return needle in open(doc_path(s)).read()


def run(s, cmd):
    if not in_doc(s, cmd):
        return {'error': f'command is not in {DOC}; only commands written in the desk run'}
    t = time.time()
    r = subprocess.run(['bash', '-c', cmd], cwd=project(s), capture_output=True, text=True, timeout=600)
    return {'out': r.stdout + r.stderr, 'rc': r.returncode, 'secs': round(time.time() - t, 1)}


def launch(s, cmd):
    """Start a program that keeps running (a viewer, a GUI) detached from the server."""
    if not in_doc(s, cmd):
        return {'error': f'command is not in {DOC}; only commands written in the desk run'}
    p = subprocess.Popen(['bash', '-c', cmd], cwd=project(s), start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {'pid': p.pid}


def open_path(s, rel):
    if not in_doc(s, rel):
        return {'error': f'path is not in {DOC}'}
    p = os.path.normpath(os.path.join(project(s), rel))
    opener = 'open' if sys.platform == 'darwin' else 'xdg-open'
    subprocess.Popen([opener, p], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {'opened': p}


ME = None   # the tailnet login of this node's user, read once from tailscale status


def me():
    global ME
    if ME is None:
        st = json.loads(subprocess.run(['tailscale', 'status', '--json'], check=True, capture_output=True).stdout)
        ME = st['User'][str(st['Self']['UserID'])]['LoginName']
    return ME


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def allowed(self):
        """Direct loopback requests pass; proxied ones (X-Forwarded-For set, or a Host that is not this
        machine) only when Tailscale Serve identifies the caller as this node's own user."""
        proxied = 'X-Forwarded-For' in self.headers or self.headers.get('Host', '').split(':')[0] not in ('127.0.0.1', 'localhost')
        return not proxied or self.headers.get('Tailscale-User-Login') == me()

    def reply(self, code, body, ctype='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype + '; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.allowed():
            return self.reply(403, {'error': 'not you'})
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if u.path == '/':
            return self.reply(200, open(f'{HERE}/desk.html', 'rb').read(), 'text/html')
        if u.path in ('/icon.svg', '/icon.png'):
            return self.reply(200, open(f'{HERE}{u.path}', 'rb').read(), {'.svg': 'image/svg+xml', '.png': 'image/png'}[u.path[-4:]])
        if u.path == '/api/projects':
            return self.reply(200, projects())
        if u.path == '/api/doc':
            d = read_doc(q['p'])
            if q.get('if') == str(d['mtime']):
                return self.reply(304, b'')
            return self.reply(200, d)
        if u.path == '/api/artifacts':
            return self.reply(200, artifacts(q['p']))
        if u.path == '/api/chat':
            return self.reply(200, chat(q['p'], q['sid']))
        self.reply(404, {'error': 'no such path'})

    def do_POST(self):
        if not self.allowed():
            return self.reply(403, {'error': 'not you'})
        if self.headers.get('X-Desk') != '1':
            return self.reply(403, {'error': 'missing X-Desk header'})
        n = int(self.headers.get('Content-Length', 0))
        u = urllib.parse.urlparse(self.path)
        if u.path == '/api/stt':   # body: raw int16 16 kHz mono; the text goes back to the message box
            q = dict(urllib.parse.parse_qsl(u.query))
            return self.reply(200, {'text': transcribe(self.rfile.read(n), q.get('lang', ''))})
        b = json.loads(self.rfile.read(n) or b'{}')
        if u.path == '/api/send':
            return self.reply(200, {'pane': send_text(b['p'], b['tab'], b['text'])})
        if u.path == '/api/run':
            return self.reply(200, run(b['p'], b['cmd']))
        if u.path == '/api/launch':
            return self.reply(200, launch(b['p'], b['cmd']))
        if u.path == '/api/open':
            return self.reply(200, open_path(b['p'], b['path']))
        self.reply(404, {'error': 'no such path'})


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    print(f'claude-desk on http://127.0.0.1:{PORT}/', flush=True)
    srv.serve_forever()
