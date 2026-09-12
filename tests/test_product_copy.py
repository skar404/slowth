import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_web_extension_versions_match_marketing_version() -> None:
    project = (ROOT / "project.yml").read_text()
    match = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', project, re.MULTILINE)
    assert match is not None
    marketing_version = match.group(1)

    manifest = json.loads((ROOT / "WebExt/manifest.json").read_text())
    assert manifest["version"] == marketing_version

    popup = (ROOT / "WebExt/app.html").read_text()
    assert f"Slowth v{marketing_version}" in popup


def test_bundled_surface_model_declares_its_license() -> None:
    metadata = json.loads(
        (ROOT / "RealtimeShield/SurfaceDetectorMetadata.json").read_text()
    )
    assert metadata["license"] == "GPL-3.0-only"
    assert metadata["licenseFile"] == "MODEL_LICENSE.md"
    assert (ROOT / "RealtimeShield" / metadata["licenseFile"]).is_file()

    exporter = (ROOT / "scripts/surface_ml.py").read_text()
    assert '"license": "GPL-3.0-only"' in exporter
    assert '"licenseFile": "MODEL_LICENSE.md"' in exporter
