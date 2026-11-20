#!/usr/bin/env python3
"""Local, unauthenticated recording receiver. No labeler or dataset writes."""
from __future__ import annotations
import argparse
import base64
import hashlib
import html
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid

HEX = re.compile(r"[a-f0-9]{64}\Z")
NAME = re.compile(r"[A-Za-z0-9_.-]{1,150}\Z")
ROUTE = re.compile(r"/v1/recordings/(motion|screenshots)/([a-f0-9-]{36})/([a-f0-9]{64})/(complete|files/([A-Za-z0-9_.-]{1,150}))\Z")
MAX_MANIFEST = 8 * 1024 * 1024


def digest(path):
    sha = hashlib.sha256(); md5 = hashlib.md5(); size = 0
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            sha.update(chunk); md5.update(chunk); size += len(chunk)
    return sha.hexdigest(), base64.b64encode(md5.digest()).decode(), size


def validate_config(value):
    if value.get('version') != 1: raise ValueError('Expected config version 1')
    profile = value['profile']
    profile['id'] = str(uuid.UUID(profile.get('id', str(uuid.uuid4()))))
    if not isinstance(profile.get('name'), str) or not 1 <= len(profile['name'].strip()) <= 80:
        raise ValueError('Connection name is required')
    url = urlsplit(profile['endpoint'])
    if not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('Invalid endpoint')
    # Access port now so malformed/out-of-range values are rejected.
    if url.port is not None and not 1 <= url.port <= 65535: raise ValueError('Invalid port')
    if profile['transport'] == 's3':
        if url.scheme != 'https': raise ValueError('S3 requires HTTPS')
        if not re.fullmatch(r'[a-z0-9-]{1,64}', profile['region']): raise ValueError('Invalid region')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', profile['bucket']) or '..' in profile['bucket']:
            raise ValueError('Invalid bucket')
        secret = value['credentials']
        for key in ['accessKeyID', 'secretAccessKey'] + (['sessionToken'] if secret.get('sessionToken') is not None else []):
            text = secret[key]
            if not isinstance(text, str) or not text or len(text) > 4096 or any(not 33 <= ord(c) <= 126 for c in text):
                raise ValueError('Invalid credentials')
    elif profile['transport'] == 'http':
        local = url.hostname == 'localhost' or url.hostname.endswith('.local')
        try:
            address = ipaddress.ip_address(url.hostname)
            local = address.is_loopback or address.is_link_local or any(address in network for network in (
                ipaddress.ip_network('10.0.0.0/8'), ipaddress.ip_network('172.16.0.0/12'),
                ipaddress.ip_network('192.168.0.0/16'), ipaddress.ip_network('100.64.0.0/10'),
                ipaddress.ip_network('fc00::/7')) if address.version == network.version)
        except ValueError: pass
        if url.scheme != 'https' and not (url.scheme == 'http' and local): raise ValueError('HTTP requires a local host')
        if value.get('credentials') is not None: raise ValueError('HTTP has no credentials')
        profile.update(region='', bucket='', prefix='')
    else: raise ValueError('Unknown transport')
    for path in (url.path, profile.get('prefix', '')):
        if '\\' in path or any(part in ('.', '..') for part in path.split('/')) or any(ord(c) < 32 for c in path):
            raise ValueError('Invalid path')
    profile.setdefault('prefix', '')
    return value


def connection_link(config):
    data = json.dumps(validate_config(config), separators=(',', ':'), ensure_ascii=False).encode()
    link = 'slowth://debug-transfer#config=' + base64.urlsafe_b64encode(data).decode().rstrip('=')
    if len(link.encode()) > 12288: raise ValueError('Connection is too large for a deeplink')
    return link


def pairing_page(config):
    import qrcode
    import qrcode.image.svg
    link = connection_link(config)
    try:
        qr = qrcode.make(link, image_factory=qrcode.image.svg.SvgPathImage, border=4)
    except qrcode.exceptions.DataOverflowError as error:
        raise ValueError('Connection data is too large for one QR code') from error
    output = io.BytesIO(); qr.save(output)
    svg = base64.b64encode(output.getvalue()).decode()
    name = html.escape(config['profile']['name'])
    return f'''<!doctype html><html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Slowth connection</title><style>body{{font:18px system-ui;max-width:640px;margin:40px auto;padding:20px}}img{{width:100%;max-width:520px}}a{{display:block;margin:20px 0}}</style>
<h1>{name}</h1><p>Scan with the iPhone camera, then save the connection in Slowth Debug.</p>
<img alt="Slowth connection QR" src="data:image/svg+xml;base64,{svg}">
<a href="{html.escape(link, quote=True)}">Open in Slowth</a>
<p>Saving a connection does not send recordings.</p></html>'''.encode()


class Receiver(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, root, config=None, max_file_bytes=512 * 1024 * 1024):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.config = config
        self.max_file_bytes = max_file_bytes
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = 'SlowthReceiver/1'
    def setup(self):
        super().setup(); self.connection.settimeout(60)
    def log_message(self, *_):
        pass  # Neither profile fragments, file names nor request headers enter logs.
    def reply(self, status, value=None):
        payload = json.dumps(value or {}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(payload)
    def route(self):
        match = ROUTE.fullmatch(self.path)
        if not match: raise ValueError('Invalid route')
        kind, session, snapshot, action, name = match.groups()
        if str(uuid.UUID(session)) != session: raise ValueError('Invalid UUID')
        name = 'COMPLETE.json' if action == 'complete' else name
        if not NAME.fullmatch(name) or name in ('.', '..') or (action != 'complete' and name == 'COMPLETE.json'):
            raise ValueError('Invalid name')
        folder = self.server.root / kind / session / snapshot
        path = folder / name
        if not path.resolve().is_relative_to(self.server.root): raise ValueError('Invalid path')
        for ancestor in (folder.parent.parent, folder.parent, folder, path):
            if ancestor.is_symlink(): raise ValueError('Symlinks are not accepted')
        return kind, session, snapshot, folder, path, action == 'complete'
    def do_GET(self):
        if self.path != '/' or self.server.config is None: return self.reply(404)
        payload = pairing_page(self.server.config)
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', "default-src 'none'; img-src data:; style-src 'unsafe-inline'")
        self.end_headers(); self.wfile.write(payload)
    def do_HEAD(self):
        try:
            with self.server.lock:
                _, _, _, _, path, _ = self.route()
                if not path.is_file(): return self.reply(404)
                sha, _, size = digest(path)
                self.send_response(200)
                self.send_header('Content-Length', str(size))
                self.send_header('X-Content-SHA256', sha)
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
        except (ValueError, OSError): self.reply(400)
    def do_PUT(self):
        temporary = None
        try:
            # No bearer token, cookies or browser-origin API access in this local protocol.
            if self.headers.get('Origin') or self.headers.get('Transfer-Encoding'): return self.reply(400)
            lengths = self.headers.get_all('Content-Length', [])
            hashes = self.headers.get_all('X-Content-SHA256', [])
            if len(lengths) != 1 or len(hashes) != 1 or not lengths[0].isdigit() or not HEX.fullmatch(hashes[0]):
                return self.reply(400)
            size = int(lengths[0]); expected = hashes[0]
            with self.server.lock:
                kind, session, snapshot, folder, path, complete = self.route()
                if size > (MAX_MANIFEST if complete else self.server.max_file_bytes): return self.reply(413)
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                with tempfile.NamedTemporaryFile(dir=folder, prefix='.upload-', delete=False) as stream:
                    temporary = Path(stream.name); remaining = size; sha = hashlib.sha256(); md5 = hashlib.md5()
                    while remaining:
                        chunk = self.rfile.read(min(1024 * 1024, remaining))
                        if not chunk: raise ValueError('Truncated upload')
                        stream.write(chunk); sha.update(chunk); md5.update(chunk); remaining -= len(chunk)
                    stream.flush(); os.fsync(stream.fileno())
                if sha.hexdigest() != expected: return self.reply(422)
                if self.headers.get('Content-MD5') != base64.b64encode(md5.digest()).decode(): return self.reply(422)
                if path.exists() and digest(path) != (expected, base64.b64encode(md5.digest()).decode(), size): return self.reply(409)
                if complete:
                    if expected != snapshot: return self.reply(422)
                    inventory = json.loads(temporary.read_bytes())
                    if inventory.get('version') != 1 or inventory.get('kind') != kind or str(uuid.UUID(inventory.get('sessionID', ''))) != session:
                        return self.reply(422)
                    files = inventory.get('files')
                    if not isinstance(files, list) or not 1 <= len(files) <= 50000: return self.reply(422)
                    names = set()
                    for entry in files:
                        name = entry['name']
                        if not NAME.fullmatch(name) or name in ('.', '..', 'COMPLETE.json') or name in names: return self.reply(422)
                        names.add(name); original = folder / name
                        if original.is_symlink() or not original.is_file(): return self.reply(409)
                        if digest(original) != (entry['sha256'], entry['md5'], entry['size']): return self.reply(422)
                elif (folder / 'COMPLETE.json').exists() and not path.exists():
                    return self.reply(409)
                os.replace(temporary, path); temporary = None
                self.reply(200, {'accepted': True, 'snapshotID': snapshot} if complete else {'sha256': expected, 'size': size})
        except (ValueError, KeyError, TypeError, OSError, socket.timeout):
            try: self.reply(400)
            except OSError: pass
        finally:
            if temporary is not None: temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    serve = sub.add_parser('serve')
    serve.add_argument('--bind', default='127.0.0.1')
    serve.add_argument('--port', type=int, default=8765)
    serve.add_argument('--root', type=Path, required=True)
    serve.add_argument('--advertise', required=True, help='Local URL reachable from the iPhone, e.g. http://192.168.1.10:8765')
    qr = sub.add_parser('qr', help='Write a private HTML QR page; do not print credentials')
    qr.add_argument('--config', type=Path, required=True)
    qr.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'qr':
            page = pairing_page(json.loads(args.config.read_text()))
            descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, 'wb') as output: output.write(page)
            os.chmod(args.output, 0o600)
            print('Private QR page written. Open it locally; it contains the connection credentials.')
        else:
            config = validate_config({'version': 1, 'profile': {'name': 'Local recordings', 'transport': 'http', 'endpoint': args.advertise}})
            pairing_page(config)  # Fail clearly before serving when qrcode is missing.
            server = Receiver((args.bind, args.port), args.root, config)
            print(f'Receiver listening on {args.bind}:{server.server_port}. Open {args.advertise}/ for the QR.', flush=True)
            try: server.serve_forever()
            except KeyboardInterrupt: pass
            finally: server.server_close()
    except ImportError:
        parser.exit(2, 'Install QR support in your Python environment: pip install qrcode\n')
    except (ValueError, KeyError, TypeError, OSError):
        parser.exit(2, 'Invalid connection settings or inaccessible file. No credentials were printed.\n')

if __name__ == '__main__': main()
