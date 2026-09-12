"""Organize and validate the private Realtime Shield image dataset.

The canonical layout is session-aware and describes an image with two
orthogonal values instead of encoding everything in an ambiguous folder name:

    sandbox/dataset/frames/<app>/<content>/<session-id>/<image>

`is_critical` is metadata, not a model class. New imports intentionally remain
`unassigned` until their session boundaries and split are reviewed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import os
import re
import shutil
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path

from PIL import Image

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}
SPLITS = {"train", "validation", "test", "unassigned"}
VALID_CONTENTS = {
    "youtube": {"normal", "shorts"},
    "instagram": {"normal", "reels", "stories"},
    "other": {"normal"},
}


@dataclass(frozen=True)
class SourceSpec:
    app: str
    content: str
    is_critical: bool

    @property
    def session_prefix(self) -> str:
        if self.app == "other" and self.is_critical:
            return "other-critical"
        return f"{self.app}-{self.content}"


# These names are the one-off folders that existed before the canonical
# dataset. Keep the misspellings here so the migration is reproducible.
LEGACY_SOURCES = {
    "youtuber-shorts": SourceSpec("youtube", "shorts", False),
    "youtube-critical": SourceSpec("youtube", "normal", True),
    "instagram-reals": SourceSpec("instagram", "reels", False),
    "instagram-critical": SourceSpec("instagram", "normal", True),
    "normal": SourceSpec("other", "normal", False),
    "critical": SourceSpec("other", "normal", True),
}


@dataclass
class DatasetRow:
    path: str
    app: str
    content: str
    is_critical: str
    session_id: str
    split: str
    captured_at: float
    device_model: str
    os_version: str
    app_version: str
    orientation: str
    source_batch: str


def image_files(folder: Path) -> list[Path]:
    if not folder.exists():
        return []
    return sorted(
        (path for path in folder.iterdir() if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES),
        key=lambda path: (path.stat().st_mtime, path.name),
    )


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_orientation(path: Path) -> str:
    with Image.open(path) as image:
        width, height = image.size
    if width == height:
        return "square"
    return "landscape" if width > height else "portrait"


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict | DatasetRow], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row) if isinstance(row, DatasetRow) else row)
    os.replace(temporary, path)


def resolve_legacy_rows(root: Path, manifest: Path) -> dict[str, dict[str, str]]:
    """Resolve stale `critical/...` paths after their files were hand-sorted."""
    rows = read_csv(manifest)
    files_by_name: dict[str, list[Path]] = defaultdict(list)
    for folder_name in LEGACY_SOURCES:
        for path in image_files(root / folder_name):
            files_by_name[path.name].append(path)

    resolved: dict[str, dict[str, str]] = {}
    for row in rows:
        name = Path(row["path"]).name
        matches = files_by_name.get(name, [])
        if len(matches) != 1:
            raise ValueError(f"legacy manifest image {name!r} has {len(matches)} filesystem matches")
        resolved[str(matches[0].relative_to(root))] = row
    return resolved


def canonical_session_ids(
    entries: list[tuple[Path, SourceSpec, dict[str, str] | None]],
) -> dict[tuple[str, str], str]:
    grouped: dict[str, list[tuple[str, float]]] = defaultdict(list)
    for path, spec, legacy in entries:
        if legacy is None:
            continue
        key = (path.parent.name, legacy["session_id"])
        captured_at = float(legacy.get("captured_at") or path.stat().st_mtime)
        grouped[spec.session_prefix].append(("\0".join(key), captured_at))

    result: dict[tuple[str, str], str] = {}
    for prefix, values in grouped.items():
        first_seen: dict[str, float] = {}
        for key, captured_at in values:
            first_seen[key] = min(first_seen.get(key, captured_at), captured_at)
        for index, key in enumerate(sorted(first_seen, key=lambda item: (first_seen[item], item)), 1):
            folder, legacy_session = key.split("\0", 1)
            result[(folder, legacy_session)] = f"{prefix}-{index:03d}"
    return result


def migrate(args: argparse.Namespace) -> None:
    root = Path(args.root).resolve()
    dataset = root / "dataset"
    manifest = dataset / "manifest.csv"
    legacy_manifest = Path(args.legacy_manifest).resolve()
    compatibility_manifest = root / "manifest.csv"

    entries: list[tuple[Path, SourceSpec, dict[str, str] | None]] = []
    resolved_legacy = resolve_legacy_rows(root, legacy_manifest)
    for folder_name, spec in LEGACY_SOURCES.items():
        for path in image_files(root / folder_name):
            entries.append((path, spec, resolved_legacy.get(str(path.relative_to(root)))))
    if not entries:
        raise ValueError("no legacy image folders found; the dataset may already be migrated")

    names = Counter(path.name for path, _, _ in entries)
    collisions = sorted(name for name, count in names.items() if count > 1)
    if collisions:
        raise ValueError(f"duplicate image names across legacy folders: {collisions[:10]}")

    session_ids = canonical_session_ids(entries)
    pending_ids = {
        folder: f"unassigned-{spec.session_prefix}-001"
        for folder, spec in LEGACY_SOURCES.items()
    }
    rows: list[DatasetRow] = []
    compatibility_rows: list[dict[str, str]] = []

    for source, spec, legacy in entries:
        folder = source.parent.name
        if legacy is None:
            session_id = pending_ids[folder]
            split = "unassigned"
            captured_at = source.stat().st_mtime
            device_model = "unknown"
            os_version = "unknown"
            app_version = "unknown"
            orientation = "portrait"
        else:
            session_id = session_ids[(folder, legacy["session_id"])]
            split = legacy["split"]
            captured_at = float(legacy["captured_at"])
            device_model = legacy.get("device_model", "unknown")
            os_version = legacy.get("ios_version", "unknown")
            app_version = legacy.get("youtube_version", "unknown") if spec.app == "youtube" else "unknown"
            orientation = legacy.get("orientation", "portrait")

        destination = dataset / "frames" / spec.app / spec.content / session_id / source.name
        relative_destination = str(destination.relative_to(dataset))
        rows.append(
            DatasetRow(
                path=relative_destination,
                app=spec.app,
                content=spec.content,
                is_critical=str(spec.is_critical).lower(),
                session_id=session_id,
                split=split,
                captured_at=captured_at,
                device_model=device_model,
                os_version=os_version,
                app_version=app_version,
                orientation=orientation,
                source_batch=folder,
            )
        )

        if legacy is not None:
            compatibility = dict(legacy)
            compatibility["path"] = str(destination.relative_to(root))
            compatibility_rows.append(compatibility)

        if args.apply:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                if file_digest(source) != file_digest(destination):
                    raise ValueError(f"destination collision with different content: {destination}")
                source.unlink()
            else:
                shutil.move(source, destination)

    rows.sort(key=lambda row: (row.app, row.content, row.session_id, row.captured_at, row.path))
    print_summary(rows)
    if not args.apply:
        print("dry run only; pass --apply to move files and write manifests")
        return

    write_csv(manifest, rows, list(DatasetRow.__annotations__))
    if compatibility_rows:
        fields = list(compatibility_rows[0])
        compatibility_rows.sort(key=lambda row: (row["session_id"], float(row["captured_at"]), row["path"]))
        archive = root / "legacy" / "original-manifest.csv"
        if not archive.exists():
            archive.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(legacy_manifest, archive)
        write_csv(compatibility_manifest, compatibility_rows, fields)

    for folder_name in LEGACY_SOURCES:
        folder = root / folder_name
        if folder.exists():
            finder_metadata = folder / ".DS_Store"
            if finder_metadata.exists():
                finder_metadata.unlink()
            if not any(folder.iterdir()):
                folder.rmdir()

    validate_manifest(manifest)
    print(f"wrote {manifest}")
    print(f"updated compatibility manifest {compatibility_manifest}")


def read_dataset_manifest(path: Path) -> list[DatasetRow]:
    with path.open(newline="") as handle:
        rows = [DatasetRow(**row) for row in csv.DictReader(handle)]
    if not rows:
        raise ValueError(f"manifest is empty: {path}")
    for row in rows:
        row.captured_at = float(row.captured_at)
    return rows


def validate_manifest(path: Path) -> list[DatasetRow]:
    rows = read_dataset_manifest(path)
    dataset = path.parent
    seen_paths: set[str] = set()
    session_splits: dict[str, set[str]] = defaultdict(set)
    session_surfaces: dict[str, set[tuple[str, str]]] = defaultdict(set)
    digests: dict[str, str] = {}

    for row in rows:
        if row.app not in VALID_CONTENTS or row.content not in VALID_CONTENTS[row.app]:
            raise ValueError(f"invalid app/content pair {row.app}/{row.content} for {row.path}")
        if row.split not in SPLITS:
            raise ValueError(f"invalid split {row.split!r} for {row.path}")
        if row.is_critical not in {"true", "false"}:
            raise ValueError(f"is_critical must be true/false for {row.path}")
        if row.orientation not in {"portrait", "landscape", "square", "unknown"}:
            raise ValueError(f"invalid orientation {row.orientation!r} for {row.path}")
        if not math.isfinite(row.captured_at):
            raise ValueError(f"captured_at must be finite for {row.path}")
        if row.path in seen_paths:
            raise ValueError(f"duplicate manifest path: {row.path}")
        seen_paths.add(row.path)
        if not (dataset / row.path).is_file():
            raise ValueError(f"manifest image is missing: {row.path}")
        digest = file_digest(dataset / row.path)
        if digest in digests:
            raise ValueError(
                f"duplicate image content: {digests[digest]} and {row.path}"
            )
        digests[digest] = row.path
        expected_prefix = Path("frames") / row.app / row.content / row.session_id
        if Path(row.path).parent != expected_prefix:
            raise ValueError(f"path does not match row metadata: {row.path}")
        session_splits[row.session_id].add(row.split)
        session_surfaces[row.session_id].add((row.app, row.content))

    leaked = {session: splits for session, splits in session_splits.items() if len(splits) != 1}
    if leaked:
        raise ValueError(f"sessions occur in multiple splits: {leaked}")
    mixed = {
        session: sorted(surfaces)
        for session, surfaces in session_surfaces.items()
        if len(surfaces) != 1
    }
    if mixed:
        raise ValueError(f"sessions contain multiple app/content classes: {mixed}")

    disk_paths = {
        str(path.relative_to(dataset))
        for path in (dataset / "frames").rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    }
    unregistered = sorted(disk_paths - seen_paths)
    if unregistered:
        raise ValueError(f"images missing from manifest: {unregistered[:10]}")
    if seen_paths - disk_paths:
        raise ValueError("manifest contains paths outside the canonical image inventory")
    return rows


def print_summary(rows: list[DatasetRow]) -> None:
    frame_counts = Counter((row.app, row.content, row.is_critical, row.split) for row in rows)
    session_rows = {row.session_id: row for row in rows}
    session_counts = Counter((row.app, row.content, row.split) for row in session_rows.values())
    print(f"frames={len(rows)} sessions={len(session_rows)}")
    for key, count in sorted(frame_counts.items()):
        print(f"  frames {key}: {count}")
    for key, count in sorted(session_counts.items()):
        print(f"  sessions {key}: {count}")


def validate(args: argparse.Namespace) -> None:
    rows = validate_manifest(Path(args.manifest).resolve())
    print_summary(rows)
    print("dataset is valid")


def add_session(args: argparse.Namespace) -> None:
    manifest = Path(args.manifest).resolve()
    dataset = manifest.parent
    source = Path(args.source).resolve()
    if args.app not in VALID_CONTENTS or args.content not in VALID_CONTENTS[args.app]:
        raise ValueError(f"invalid app/content pair {args.app}/{args.content}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", args.session):
        raise ValueError("session id must contain only lowercase letters, digits, dots, dashes, or underscores")
    sources = image_files(source)
    if not sources:
        raise ValueError(f"no images found in {source}")

    existing = validate_manifest(manifest)
    same_session = [row for row in existing if row.session_id == args.session]
    for row in same_session:
        if (row.app, row.content, row.split) != (args.app, args.content, args.split):
            raise ValueError(f"session {args.session!r} already exists with different metadata")

    destination_folder = dataset / "frames" / args.app / args.content / args.session
    additions: list[tuple[Path, Path, DatasetRow]] = []
    known_paths = {row.path for row in existing}
    for source_image in sources:
        destination = destination_folder / source_image.name
        relative = str(destination.relative_to(dataset))
        if relative in known_paths or destination.exists():
            raise ValueError(f"destination already exists: {relative}")
        additions.append(
            (
                source_image,
                destination,
                DatasetRow(
                    path=relative,
                    app=args.app,
                    content=args.content,
                    is_critical=str(args.critical).lower(),
                    session_id=args.session,
                    split=args.split,
                    captured_at=source_image.stat().st_mtime,
                    device_model=args.device_model,
                    os_version=args.os_version,
                    app_version=args.app_version,
                    orientation=(
                        image_orientation(source_image)
                        if args.orientation == "auto"
                        else args.orientation
                    ),
                    source_batch=args.source_batch or source.name,
                ),
            )
        )

    destination_folder.mkdir(parents=True, exist_ok=True)
    for source_image, destination, _ in additions:
        if args.move:
            shutil.move(source_image, destination)
        else:
            shutil.copy2(source_image, destination)
    rows = existing + [row for _, _, row in additions]
    rows.sort(key=lambda row: (row.app, row.content, row.session_id, row.captured_at, row.path))
    write_csv(manifest, rows, list(DatasetRow.__annotations__))
    validate_manifest(manifest)
    print(f"registered {len(additions)} images as session {args.session} ({args.split})")


def assign_split(args: argparse.Namespace) -> None:
    """Assign one complete reviewed session without permitting frame-level splits."""
    manifest = Path(args.manifest).resolve()
    rows = validate_manifest(manifest)
    selected = [row for row in rows if row.session_id == args.session]
    if not selected:
        raise ValueError(f"unknown session: {args.session}")
    current_splits = {row.split for row in selected}
    if current_splits != {args.from_split}:
        raise ValueError(
            f"session {args.session!r} has split {sorted(current_splits)}, "
            f"expected {args.from_split!r}"
        )
    for row in selected:
        row.split = args.split
    write_csv(manifest, rows, list(DatasetRow.__annotations__))
    validate_manifest(manifest)
    print(f"assigned {len(selected)} frames from session {args.session} to {args.split}")


def parse_partition(value: str) -> tuple[str, str, str, str]:
    try:
        session, split, first, last = value.split(":", 3)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "partition must be SESSION:SPLIT:FIRST_IMAGE:LAST_IMAGE"
        ) from error
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", session):
        raise argparse.ArgumentTypeError(f"invalid destination session id: {session!r}")
    if split not in SPLITS - {"unassigned"}:
        raise argparse.ArgumentTypeError(f"invalid destination split: {split!r}")
    if not first or not last:
        raise argparse.ArgumentTypeError("partition image names must not be empty")
    return session, split, first, last


def split_session(args: argparse.Namespace) -> None:
    """Split one reviewed capture into complete sessions and move its images."""
    manifest = Path(args.manifest).resolve()
    dataset = manifest.parent
    rows = validate_manifest(manifest)
    selected = sorted(
        (row for row in rows if row.session_id == args.session),
        key=lambda row: (row.captured_at, row.path),
    )
    if not selected:
        raise ValueError(f"unknown session: {args.session}")
    current_splits = {row.split for row in selected}
    if current_splits != {args.from_split}:
        raise ValueError(
            f"session {args.session!r} has split {sorted(current_splits)}, "
            f"expected {args.from_split!r}"
        )

    existing_sessions = {row.session_id for row in rows} - {args.session}
    destination_sessions = [session for session, _, _, _ in args.partition]
    duplicates = sorted(
        session for session, count in Counter(destination_sessions).items() if count > 1
    )
    if duplicates:
        raise ValueError(f"duplicate destination sessions: {duplicates}")
    collisions = sorted(set(destination_sessions) & existing_sessions)
    if collisions:
        raise ValueError(f"destination sessions already exist: {collisions}")

    positions: dict[str, int] = {}
    for index, row in enumerate(selected):
        name = Path(row.path).name
        if name in positions:
            raise ValueError(f"source session contains duplicate image name: {name}")
        positions[name] = index

    assignments: dict[str, tuple[str, str]] = {}
    for session, split, first, last in args.partition:
        if first not in positions or last not in positions:
            raise ValueError(f"partition {session!r} names images outside the source session")
        start, end = positions[first], positions[last]
        if start > end:
            raise ValueError(f"partition {session!r} has a reversed image range")
        for row in selected[start : end + 1]:
            if row.path in assignments:
                raise ValueError(f"partition ranges overlap at {Path(row.path).name}")
            assignments[row.path] = (session, split)

    missing = [Path(row.path).name for row in selected if row.path not in assignments]
    if missing:
        raise ValueError(f"partition ranges do not cover source session: {missing[:10]}")

    moves: list[tuple[Path, Path]] = []
    for row in selected:
        destination_session, destination_split = assignments[row.path]
        source = dataset / row.path
        destination = (
            dataset
            / "frames"
            / row.app
            / row.content
            / destination_session
            / source.name
        )
        if destination.exists():
            raise ValueError(f"destination already exists: {destination.relative_to(dataset)}")
        moves.append((source, destination))
        row.path = str(destination.relative_to(dataset))
        row.session_id = destination_session
        row.split = destination_split

    original_rows = read_dataset_manifest(manifest)
    completed: list[tuple[Path, Path]] = []
    try:
        for source, destination in moves:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(source, destination)
            completed.append((source, destination))
        rows.sort(key=lambda row: (row.app, row.content, row.session_id, row.captured_at, row.path))
        write_csv(manifest, rows, list(DatasetRow.__annotations__))
        validate_manifest(manifest)
    except Exception:
        for source, destination in reversed(completed):
            source.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(destination, source)
        write_csv(manifest, original_rows, list(DatasetRow.__annotations__))
        raise

    source_folder = moves[0][0].parent
    if source_folder.exists() and not any(source_folder.iterdir()):
        source_folder.rmdir()
    counts = Counter((row.session_id, row.split) for row in selected)
    for (session, split), count in sorted(counts.items()):
        print(f"created session {session} ({split}) with {count} frames")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    command = commands.add_parser("migrate-legacy", help="move legacy folders into the canonical layout")
    command.add_argument("root", help="private dataset root, normally sandbox")
    command.add_argument("--legacy-manifest", default="sandbox/manifest.csv")
    command.add_argument("--apply", action="store_true", help="perform the migration; otherwise only print a plan")
    command.set_defaults(function=migrate)

    command = commands.add_parser("validate", help="validate layout, metadata and split isolation")
    command.add_argument("manifest")
    command.set_defaults(function=validate)

    command = commands.add_parser("add-session", help="copy or move a labelled image session into the dataset")
    command.add_argument("manifest")
    command.add_argument("source")
    command.add_argument("--app", required=True, choices=sorted(VALID_CONTENTS))
    command.add_argument("--content", required=True)
    command.add_argument("--session", required=True)
    command.add_argument("--split", choices=sorted(SPLITS), default="unassigned")
    command.add_argument("--critical", action="store_true")
    command.add_argument("--device-model", default="unknown")
    command.add_argument("--os-version", default="unknown")
    command.add_argument("--app-version", default="unknown")
    command.add_argument(
        "--orientation",
        choices=("auto", "portrait", "landscape", "square", "unknown"),
        default="auto",
    )
    command.add_argument("--source-batch")
    command.add_argument("--move", action="store_true", help="move source images instead of copying them")
    command.set_defaults(function=add_session)

    command = commands.add_parser("assign-split", help="assign one complete reviewed session to a split")
    command.add_argument("manifest")
    command.add_argument("session")
    command.add_argument("split", choices=sorted(SPLITS - {"unassigned"}))
    command.add_argument("--from-split", choices=sorted(SPLITS), default="unassigned")
    command.set_defaults(function=assign_split)

    command = commands.add_parser(
        "split-session", help="split one capture into complete image-range sessions"
    )
    command.add_argument("manifest")
    command.add_argument("session")
    command.add_argument(
        "--partition",
        action="append",
        type=parse_partition,
        required=True,
        help="SESSION:SPLIT:FIRST_IMAGE:LAST_IMAGE; repeat to cover the source session",
    )
    command.add_argument("--from-split", choices=sorted(SPLITS), required=True)
    command.set_defaults(function=split_session)
    return root


def main() -> None:
    args = parser().parse_args()
    args.function(args)


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error
