
"""App utilities must not recreate the retired sandbox directory."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_log_collection_default_uses_private_logs_directory():
    script = (ROOT / 'scripts/collect_realtime_shield_logs.sh').read_text()
    assert 'output_root="${3:-logs/realtime-shield}"' in script
    assert 'sandbox/' not in script
    assert '/logs/' in (ROOT / '.gitignore').read_text().splitlines()
