import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_web_extension_versions_match_marketing_version() -> None:
    project = (ROOT / "project.yml").read_text()
    match = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', project, re.MULTILINE)
    assert match is not None
    marketing_version = match.group(1)

    manifest = json.loads((ROOT / "WebExt/manifest.json").read_text())
    assert manifest["version"] == marketing_version

    popup = (ROOT / "WebExt/app.html").read_text()
    assert f"Slowth v{marketing_version}" in popup


def test_historical_model_license_notice_is_available() -> None:
    license_text = (ROOT / "RealtimeShield/MODEL_LICENSE.md").read_text()
    assert "GPL-3.0-only" in license_text
    assert (ROOT / "LICENSE").is_file()
