import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('research_boundary', ROOT / 'scripts/verify_no_research_code.py')
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)

class ResearchBoundaryTests(unittest.TestCase):
    def test_no_research_implementation_or_permissions_in_app_source(self):
        boundary.verify_sources(ROOT)

    def test_inspects_debug_dylib_and_extension_not_only_host_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            extension = app / 'PlugIns/Broadcast.appex'
            extension.mkdir(parents=True)
            for bundle, name in ((app, 'App'), (extension, 'Broadcast')):
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name}))
                (bundle / name).write_bytes(b'production runtime')
            boundary.verify_bundle(app)
            dylib = extension / 'Broadcast.debug.dylib'
            dylib.write_bytes(b'Swift symbol: SessionCapture')
            with self.assertRaises(AssertionError): boundary.verify_bundle(app)
            dylib.write_bytes(b'production runtime')
            (extension / 'Broadcast').write_bytes(b'MotionVideoRecorder')
            with self.assertRaises(AssertionError): boundary.verify_bundle(app)
