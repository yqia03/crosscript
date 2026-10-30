"""Bounded local protocol fixture shared by real-engine feature matrices."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time

class ControlledService:
    def __init__(self, response, delay=0, status=200, usage=True):
        self.response, self.delay = response, delay
        self.status, self.usage = status, usage
        self.requests, self.active, self.maximum_active = [], 0, 0
        self.lock = threading.Lock()
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                with owner.lock:
                    owner.active += 1; owner.maximum_active = max(owner.active, owner.maximum_active)
                    owner.requests.append({'time': time.monotonic(), 'request': request, 'dashScopeHeader': self.headers.get('X-DashScope-DataInspection')})
                try:
                    if owner.delay: time.sleep(owner.delay)
                    result = owner.response(request)
                    value = {'id': 'controlled', 'object': 'chat.completion', 'created': 0, 'model': request['model'], 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': result}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120}}
                    if not owner.usage: value.pop('usage')
                    if owner.status != 200: value = {'error': {'message': 'CONTROLLED_PRIVATE_ERROR_DO_NOT_LOG', 'type': 'rate_limit_error', 'code': 'rate_limit'}}
                    body = json.dumps(value, ensure_ascii=False).encode()
                    self.send_response(owner.status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
                finally:
                    with owner.lock: owner.active -= 1
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
    @property
    def endpoint(self): return f'http://127.0.0.1:{self.server.server_port}/v1'
    def reset(self):
        assert self.active == 0
        self.requests.clear(); self.maximum_active = 0
    def close(self): self.server.shutdown()
