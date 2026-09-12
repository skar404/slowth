import csv
from argparse import Namespace
from collections import Counter
from pathlib import Path

import pytest

from scripts import realtime_dataset


def write_manifest(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(realtime_dataset.DatasetRow.__annotations__))
        writer.writeheader()
        writer.writerows(rows)


def canonical_row(path: str, session: str = "youtube-shorts-001", split: str = "train") -> dict:
    return {
        "path": path,
        "app": "youtube",
        "content": "shorts",
        "is_critical": "false",
        "session_id": session,
        "split": split,
        "captured_at": "1.0",
        "device_model": "unknown",
        "os_version": "unknown",
        "app_version": "unknown",
        "orientation": "portrait",
        "source_batch": "test",
    }


def test_validate_accepts_canonical_inventory(tmp_path: Path):
    image = tmp_path / "frames/youtube/shorts/youtube-shorts-001/frame.png"
    image.parent.mkdir(parents=True)
    image.write_bytes(b"image")
    manifest = tmp_path / "manifest.csv"
    write_manifest(manifest, [canonical_row(str(image.relative_to(tmp_path)))])

    rows = realtime_dataset.validate_manifest(manifest)

    assert len(rows) == 1


def test_validate_rejects_session_split_leakage(tmp_path: Path):
    first = tmp_path / "frames/youtube/shorts/youtube-shorts-001/first.png"
    second = tmp_path / "frames/youtube/shorts/youtube-shorts-001/second.png"
    first.parent.mkdir(parents=True)
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    manifest = tmp_path / "manifest.csv"
    rows = [canonical_row(str(first.relative_to(tmp_path)), split="train")]
    rows.append(canonical_row(str(second.relative_to(tmp_path)), split="test"))
    write_manifest(manifest, rows)

    with pytest.raises(ValueError, match="multiple splits"):
        realtime_dataset.validate_manifest(manifest)


def test_validate_rejects_multiple_surfaces_in_one_session(tmp_path: Path):
    first = tmp_path / "frames/youtube/shorts/mixed-session/first.png"
    second = tmp_path / "frames/youtube/normal/mixed-session/second.png"
    first.parent.mkdir(parents=True)
    second.parent.mkdir(parents=True)
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    manifest = tmp_path / "manifest.csv"
    rows = [canonical_row(str(first.relative_to(tmp_path)), session="mixed-session")]
    normal = canonical_row(str(second.relative_to(tmp_path)), session="mixed-session")
    normal["content"] = "normal"
    write_manifest(manifest, rows + [normal])

    with pytest.raises(ValueError, match="multiple app/content classes"):
        realtime_dataset.validate_manifest(manifest)


def test_validate_rejects_duplicate_image_content(tmp_path: Path):
    first = tmp_path / "frames/youtube/shorts/first/first.png"
    second = tmp_path / "frames/youtube/shorts/second/second.png"
    first.parent.mkdir(parents=True)
    second.parent.mkdir(parents=True)
    first.write_bytes(b"same image")
    second.write_bytes(b"same image")
    manifest = tmp_path / "manifest.csv"
    write_manifest(
        manifest,
        [
            canonical_row(str(first.relative_to(tmp_path)), session="first"),
            canonical_row(str(second.relative_to(tmp_path)), session="second"),
        ],
    )

    with pytest.raises(ValueError, match="duplicate image content"):
        realtime_dataset.validate_manifest(manifest)


def test_image_orientation_uses_pixel_dimensions(tmp_path: Path):
    from PIL import Image

    portrait = tmp_path / "portrait.png"
    landscape = tmp_path / "landscape.png"
    Image.new("RGB", (10, 20)).save(portrait)
    Image.new("RGB", (20, 10)).save(landscape)

    assert realtime_dataset.image_orientation(portrait) == "portrait"
    assert realtime_dataset.image_orientation(landscape) == "landscape"


def test_add_session_defaults_to_unassigned_and_copies_source(tmp_path: Path):
    manifest = tmp_path / "dataset/manifest.csv"
    first = tmp_path / "dataset/frames/youtube/shorts/youtube-shorts-001/first.png"
    first.parent.mkdir(parents=True)
    first.write_bytes(b"first")
    write_manifest(manifest, [canonical_row(str(first.relative_to(manifest.parent)))])
    source = tmp_path / "import"
    source.mkdir()
    imported = source / "second.png"
    imported.write_bytes(b"second")

    realtime_dataset.add_session(
        Namespace(
            manifest=str(manifest),
            source=str(source),
            app="instagram",
            content="reels",
            session="instagram-reels-002",
            split="unassigned",
            critical=False,
            device_model="iphone",
            os_version="1",
            app_version="2",
            orientation="portrait",
            source_batch=None,
            move=False,
        )
    )

    rows = realtime_dataset.validate_manifest(manifest)
    added = next(row for row in rows if row.session_id == "instagram-reels-002")
    assert added.split == "unassigned"
    assert imported.exists()


def test_assign_split_changes_the_complete_session(tmp_path: Path):
    manifest = tmp_path / "manifest.csv"
    rows = []
    for name in ("first.png", "second.png"):
        image = tmp_path / f"frames/youtube/shorts/pending/{name}"
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(name.encode())
        rows.append(
            canonical_row(
                str(image.relative_to(tmp_path)), session="pending", split="unassigned"
            )
        )
    write_manifest(manifest, rows)

    realtime_dataset.assign_split(
        Namespace(
            manifest=str(manifest),
            session="pending",
            split="train",
            from_split="unassigned",
        )
    )

    assigned = realtime_dataset.validate_manifest(manifest)
    assert {row.split for row in assigned} == {"train"}


def test_split_session_moves_ranges_and_updates_manifest(tmp_path: Path):
    manifest = tmp_path / "manifest.csv"
    rows = []
    for index in range(1, 7):
        image = tmp_path / f"frames/instagram/reels/capture/IMG_{index:04d}.PNG"
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(str(index).encode())
        item = canonical_row(
            str(image.relative_to(tmp_path)), session="capture", split="train"
        )
        item.update(app="instagram", content="reels", captured_at=str(index))
        rows.append(item)
    write_manifest(manifest, rows)

    realtime_dataset.split_session(
        Namespace(
            manifest=str(manifest),
            session="capture",
            from_split="train",
            partition=[
                ("reels-validation", "validation", "IMG_0001.PNG", "IMG_0002.PNG"),
                ("reels-test", "test", "IMG_0003.PNG", "IMG_0004.PNG"),
                ("reels-train", "train", "IMG_0005.PNG", "IMG_0006.PNG"),
            ],
        )
    )

    partitioned = realtime_dataset.validate_manifest(manifest)
    assert Counter((row.session_id, row.split) for row in partitioned) == {
        ("reels-validation", "validation"): 2,
        ("reels-test", "test"): 2,
        ("reels-train", "train"): 2,
    }
    assert not (tmp_path / "frames/instagram/reels/capture").exists()
