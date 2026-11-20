import base64
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

spec = importlib.util.spec_from_file_location('receiver', Path(__file__).parents[1] / 'scripts/debug_transfer_receiver.py')
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class TransferReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.server = receiver.Receiver(('127.0.0.1', 0), self.temp.name, max_file_bytes=1024 * 1024)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.session = str(uuid.uuid4())

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port)
        connection.request(method, path, body, headers or {})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def put(self, path, data, **extra):
        headers = {'X-Content-SHA256': hashlib.sha256(data).hexdigest(),
                   'Content-MD5': base64.b64encode(hashlib.md5(data).digest()).decode(), **extra}
        return self.request('PUT', path, data, headers)

    def snapshot(self, kind, files):
        entries = [{'name': name, 'size': len(value), 'sha256': hashlib.sha256(value).hexdigest(),
                    'md5': base64.b64encode(hashlib.md5(value).digest()).decode(), 'contentType': 'application/octet-stream'}
                   for name, value in files.items()]
        data = json.dumps({'version': 1, 'kind': kind, 'sessionID': self.session.upper(), 'files': entries}, sort_keys=True).encode()
        sha = hashlib.sha256(data).hexdigest()
        path = f'/v1/recordings/{kind}/{self.session}/{sha}'
        return data, sha, path

    def test_both_recording_types_round_trip_without_token(self):
        for kind, files in [('screenshots', {'frame_000001.png': b'original PNG bytes', 'session.json': b'{}'}),
                            ('motion', {'motion.csv': b'time,x,y,z\n1,0,0,1\n', 'samples.json': b'[]', 'session.json': b'{}'})]:
            data, sha, path = self.snapshot(kind, files)
            self.assertEqual(self.put(path + '/complete', data)[0], 409)
            for name, body in files.items():
                self.assertEqual(self.request('HEAD', path + '/files/' + name)[0], 404)
                self.assertEqual(self.put(path + '/files/' + name, body)[0], 200)
                status, headers, _ = self.request('HEAD', path + '/files/' + name)
                self.assertEqual(status, 200)
                self.assertEqual(headers['X-Content-SHA256'], hashlib.sha256(body).hexdigest())
                self.assertEqual(int(headers['Content-Length']), len(body))
                self.assertEqual(self.put(path + '/files/' + name, body)[0], 200)
                self.assertEqual(self.put(path + '/files/' + name, b'changed')[0], 409)
            status, _, response = self.put(path + '/complete', data)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(response), {'accepted': True, 'snapshotID': sha})
            for name, body in files.items():
                self.assertEqual((Path(self.temp.name) / kind / self.session / sha / name).read_bytes(), body)
            self.assertEqual(self.request('HEAD', path + '/complete')[0], 200)

    def test_corruption_and_finalization_fail_closed(self):
        data, sha, path = self.snapshot('motion', {'samples.json': b'[]'})
        self.assertEqual(self.put(path + '/files/samples.json', b'[]', **{'X-Content-SHA256': '0' * 64})[0], 422)
        self.assertEqual(self.put(path + '/files/samples.json', b'[]', **{'Content-MD5': 'wrong'})[0], 422)
        self.assertEqual(self.put(path + '/files/samples.json', b'[]')[0], 200)
        stored = Path(self.temp.name) / 'motion' / self.session / sha / 'samples.json'
        stored.write_bytes(b'corrupted')
        self.assertEqual(self.put(path + '/complete', data)[0], 422)
        self.assertFalse(stored.with_name('COMPLETE.json').exists())
        self.assertFalse(list(Path(self.temp.name).rglob('.upload-*')))

    def test_unsafe_paths_and_cross_origin_requests(self):
        _, _, path = self.snapshot('motion', {'samples.json': b'[]'})
        for name in ['..', '%2e%2e', 'folder/file', 'COMPLETE.json']:
            self.assertEqual(self.put(path + '/files/' + name, b'[]')[0], 400)
        self.assertEqual(self.put(path + '/files/a', b'x', Origin='http://example.com')[0], 400)
        self.assertEqual(self.request('PUT', path + '/files/a', b'', {'Content-Length': str(1024 * 1024 + 1), 'X-Content-SHA256': '0' * 64})[0], 413)

    def test_symlinks_are_not_followed(self):
        _, sha, path = self.snapshot('motion', {'samples.json': b'[]'})
        folder = Path(self.temp.name) / 'motion' / self.session / sha
        folder.mkdir(parents=True)
        with tempfile.TemporaryDirectory() as other:
            target = Path(other) / 'private'; target.write_bytes(b'private')
            (folder / 'samples.json').symlink_to(target)
            self.assertEqual(self.put(path + '/files/samples.json', b'[]')[0], 400)
            self.assertEqual(self.request('HEAD', path + '/files/samples.json')[0], 400)
            self.assertEqual(target.read_bytes(), b'private')

    def test_link_config_matches_client_schema(self):
        config = {'version': 1, 'profile': {'name': 'LAN', 'transport': 'http', 'endpoint': 'http://192.168.1.3:8765'}}
        link = receiver.connection_link(config)
        encoded = link.split('config=')[1]
        decoded = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
        self.assertEqual(decoded['profile']['transport'], 'http')
        self.assertNotIn('credentials', decoded)
        self.assertEqual(decoded['profile']['region'], '')
        config['profile']['endpoint'] = 'http://8.8.8.8'
        with self.assertRaises(ValueError): receiver.connection_link(config)


if __name__ == '__main__': unittest.main()
