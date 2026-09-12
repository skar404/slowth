"""Train, evaluate, and export the experimental multi-class SurfaceDetector.

Examples:
    uv run python scripts/surface_ml.py train \
        sandbox/dataset/manifest.csv sandbox/surface-detector.pt
    uv run python scripts/surface_ml.py evaluate \
        sandbox/dataset/manifest.csv sandbox/surface-detector.pt --split validation
    uv run python scripts/surface_ml.py export \
        sandbox/surface-detector.pt sandbox/SurfaceDetector.mlpackage \
        sandbox/SurfaceDetectorMetadata.json

The model has one app head plus app-specific content heads. Split assignment
is session-level, and test data is never used while training or calibrating
confidence thresholds.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import shutil
import subprocess
import sys
from collections import Counter, defaultdict
from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

if __package__:
    from scripts.realtime_dataset import DatasetRow, validate_manifest
else:
    from realtime_dataset import DatasetRow, validate_manifest

INPUT_WIDTH = 192
INPUT_HEIGHT = 384
ARCHITECTURE = "spatial-v2"
INFERENCE_INTERVAL_SECONDS = 0.25
REQUIRED_CONSECUTIVE_HITS = 3
OBSERVATION_WINDOW_FRAMES = 5
TARGET_SESSION_RECALL = 0.95
MAX_P95_DETECTION_SECONDS = 2.0
CRITICAL_WEIGHT = 5.0
CRITICAL_SCORE_MARGIN = 0.025
CLASS_LABELS = (
    "youtube_shorts",
    "youtube_normal",
    "instagram_reels",
    "instagram_stories",
    "instagram_normal",
    "other_app",
)
APP_LABELS = ("youtube", "instagram", "other")
YOUTUBE_CONTENT_LABELS = ("shorts", "normal")
INSTAGRAM_CONTENT_LABELS = ("reels", "stories", "normal")
TARGET_LABELS = ("youtube_shorts", "instagram_reels", "instagram_stories")
CLASS_INDEX = {label: index for index, label in enumerate(CLASS_LABELS)}
APP_INDEX = {label: index for index, label in enumerate(APP_LABELS)}
YOUTUBE_CONTENT_INDEX = {
    label: index for index, label in enumerate(YOUTUBE_CONTENT_LABELS)
}
INSTAGRAM_CONTENT_INDEX = {
    label: index for index, label in enumerate(INSTAGRAM_CONTENT_LABELS)
}
ROW_LABELS = {
    ("youtube", "shorts"): "youtube_shorts",
    ("youtube", "normal"): "youtube_normal",
    ("instagram", "reels"): "instagram_reels",
    ("instagram", "stories"): "instagram_stories",
    ("instagram", "normal"): "instagram_normal",
    ("other", "normal"): "other_app",
}
EVALUATION_SPLITS = {"validation", "test"}


def label_for_row(row: DatasetRow) -> str:
    try:
        return ROW_LABELS[(row.app, row.content)]
    except KeyError as error:
        raise ValueError(
            f"{row.app}/{row.content} is not supported by the six-class SurfaceDetector"
        ) from error


def rows_for_split(
    rows: list[DatasetRow], split: str, *, require_all_classes: bool = True
) -> list[DatasetRow]:
    selected = [row for row in rows if row.split == split]
    if not selected:
        raise ValueError(f"no rows in {split} split")
    labels = {label_for_row(row) for row in selected}
    missing = sorted(set(CLASS_LABELS) - labels)
    if require_all_classes and missing:
        raise ValueError(f"{split} split is missing classes: {missing}")
    return selected


def torch_modules():
    import torch
    from torch import nn
    from torch.utils.data import DataLoader, Dataset

    return torch, nn, DataLoader, Dataset


def build_model():
    _, nn, _, _ = torch_modules()

    class DepthwiseBlock(nn.Module):
        def __init__(self, input_channels: int, output_channels: int, stride: int):
            super().__init__()
            self.layers = nn.Sequential(
                nn.Conv2d(
                    input_channels,
                    input_channels,
                    kernel_size=3,
                    stride=stride,
                    padding=1,
                    groups=input_channels,
                    bias=False,
                ),
                nn.BatchNorm2d(input_channels),
                nn.ReLU(inplace=True),
                nn.Conv2d(input_channels, output_channels, kernel_size=1, bias=False),
                nn.BatchNorm2d(output_channels),
                nn.ReLU(inplace=True),
            )

        def forward(self, value):
            return self.layers(value)

    class SurfaceCNN(nn.Module):
        def __init__(self):
            super().__init__()
            self.features = nn.Sequential(
                nn.Conv2d(3, 24, kernel_size=3, stride=2, padding=1, bias=False),
                nn.BatchNorm2d(24),
                nn.ReLU(inplace=True),
                DepthwiseBlock(24, 32, 2),
                DepthwiseBlock(32, 48, 2),
                DepthwiseBlock(48, 64, 2),
                DepthwiseBlock(64, 96, 2),
            )
            self.pool = nn.AdaptiveAvgPool2d((6, 3))
            self.embedding = nn.Sequential(
                nn.Linear(96 * 6 * 3, 128),
                nn.ReLU(inplace=True),
                nn.Dropout(p=0.2),
            )
            self.app_head = nn.Linear(128, len(APP_LABELS))
            self.youtube_content_head = nn.Linear(128, len(YOUTUBE_CONTENT_LABELS))
            self.instagram_content_head = nn.Linear(128, len(INSTAGRAM_CONTENT_LABELS))

        def forward(self, value):
            value = self.features(value)
            value = self.embedding(self.pool(value).flatten(1))
            return (
                self.app_head(value),
                self.youtube_content_head(value),
                self.instagram_content_head(value),
            )

    return SurfaceCNN()


# Keep the complete canonical dataset's resized tensors in memory.  A smaller
# cache thrashes once training shuffles more than 512 frames and repeatedly
# decodes multi-megapixel PNGs on every epoch.
@lru_cache(maxsize=4096)
def resized_rgb(path: str) -> np.ndarray:
    with Image.open(path) as source:
        image = source.convert("RGB").resize((INPUT_WIDTH, INPUT_HEIGHT), Image.Resampling.BILINEAR)
    array = np.asarray(image, dtype=np.uint8)
    array.setflags(write=False)
    return array


def image_tensor(path: Path, augment: bool):
    torch, _, _, _ = torch_modules()
    image = Image.fromarray(resized_rgb(str(path)).copy(), mode="RGB")
    if augment:
        image = ImageEnhance.Brightness(image).enhance(random.uniform(0.85, 1.15))
        image = ImageEnhance.Contrast(image).enhance(random.uniform(0.85, 1.15))
        image = ImageEnhance.Color(image).enhance(random.uniform(0.9, 1.1))
        if random.random() < 0.2:
            image = image.filter(ImageFilter.GaussianBlur(radius=random.uniform(0.1, 0.7)))
    array = np.asarray(image, dtype=np.float32) / 255.0
    return torch.from_numpy(array).permute(2, 0, 1)


def class_balance_weights(rows: list[DatasetRow]) -> dict[str, float]:
    counts = Counter(label_for_row(row) for row in rows)
    missing = sorted(set(CLASS_LABELS) - set(counts))
    if missing:
        raise ValueError(f"training split is missing classes: {missing}")
    total = len(rows)
    return {label: total / (len(CLASS_LABELS) * counts[label]) for label in CLASS_LABELS}


def training_sample_weights(
    rows: list[DatasetRow], *, critical_weight: float = CRITICAL_WEIGHT
) -> list[float]:
    if critical_weight <= 0:
        raise ValueError("critical weight must be positive")
    class_weights = class_balance_weights(rows)
    return [
        class_weights[label_for_row(row)]
        * (critical_weight if row.is_critical == "true" else 1.0)
        for row in rows
    ]


def make_dataset(rows: list[DatasetRow], root: Path, augment: bool, weights: list[float] | None = None):
    torch, _, _, Dataset = torch_modules()
    sample_weights = weights or [1.0] * len(rows)
    if len(sample_weights) != len(rows):
        raise ValueError("sample weights must match dataset rows")

    class Frames(Dataset):
        def __len__(self):
            return len(rows)

        def __getitem__(self, index):
            row = rows[index]
            youtube_target = YOUTUBE_CONTENT_INDEX.get(row.content, 0) if row.app == "youtube" else 0
            instagram_target = (
                INSTAGRAM_CONTENT_INDEX.get(row.content, 0) if row.app == "instagram" else 0
            )
            return (
                image_tensor(root / row.path, augment=augment),
                torch.tensor(APP_INDEX[row.app], dtype=torch.long),
                torch.tensor(youtube_target, dtype=torch.long),
                torch.tensor(instagram_target, dtype=torch.long),
                torch.tensor(float(row.app == "youtube"), dtype=torch.float32),
                torch.tensor(float(row.app == "instagram"), dtype=torch.float32),
                torch.tensor(sample_weights[index], dtype=torch.float32),
            )

    return Frames()


def resolve_device(requested: str):
    torch, _, _, _ = torch_modules()
    if requested == "auto":
        return torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    if requested == "mps" and not torch.backends.mps.is_available():
        raise ValueError("MPS was requested but is not available")
    return torch.device(requested)


def predict_heads(model, rows: list[DatasetRow], root: Path, device=None) -> dict[str, list[list[float]]]:
    torch, _, DataLoader, _ = torch_modules()
    device = device or torch.device("cpu")
    loader = DataLoader(make_dataset(rows, root, augment=False), batch_size=32, shuffle=False)
    model.to(device).eval()
    output = {"app": [], "youtube_content": [], "instagram_content": []}
    with torch.no_grad():
        for images, *_ in loader:
            app_logits, youtube_logits, instagram_logits = model(images.to(device))
            output["app"].extend(torch.softmax(app_logits, dim=1).cpu().tolist())
            output["youtube_content"].extend(
                torch.softmax(youtube_logits, dim=1).cpu().tolist()
            )
            output["instagram_content"].extend(
                torch.softmax(instagram_logits, dim=1).cpu().tolist()
            )
    return output


def joint_probabilities(heads: dict[str, list[list[float]]]) -> list[list[float]]:
    counts = {len(values) for values in heads.values()}
    if len(counts) != 1:
        raise ValueError("probability heads have different batch lengths")
    output = []
    for app, youtube, instagram in zip(
        heads["app"],
        heads["youtube_content"],
        heads["instagram_content"],
        strict=True,
    ):
        output.append(
            [
                app[APP_INDEX["youtube"]] * youtube[YOUTUBE_CONTENT_INDEX["shorts"]],
                app[APP_INDEX["youtube"]] * youtube[YOUTUBE_CONTENT_INDEX["normal"]],
                app[APP_INDEX["instagram"]]
                * instagram[INSTAGRAM_CONTENT_INDEX["reels"]],
                app[APP_INDEX["instagram"]]
                * instagram[INSTAGRAM_CONTENT_INDEX["stories"]],
                app[APP_INDEX["instagram"]]
                * instagram[INSTAGRAM_CONTENT_INDEX["normal"]],
                app[APP_INDEX["other"]],
            ]
        )
    return output


def predict_rows(model, rows: list[DatasetRow], root: Path, device=None) -> list[list[float]]:
    return joint_probabilities(predict_heads(model, rows, root, device))


def frame_metrics(rows: list[DatasetRow], probabilities: list[list[float]]) -> dict:
    matrix = [[0 for _ in CLASS_LABELS] for _ in CLASS_LABELS]
    for row, scores in zip(rows, probabilities, strict=True):
        actual = CLASS_INDEX[label_for_row(row)]
        predicted = int(np.argmax(scores))
        matrix[actual][predicted] += 1
    per_class = {}
    for label, index in CLASS_INDEX.items():
        true_positive = matrix[index][index]
        actual_count = sum(matrix[index])
        predicted_count = sum(row[index] for row in matrix)
        per_class[label] = {
            "precision": true_positive / predicted_count if predicted_count else 0.0,
            "recall": true_positive / actual_count if actual_count else 0.0,
            "support": actual_count,
        }
    correct = sum(matrix[index][index] for index in range(len(CLASS_LABELS)))
    return {
        "accuracy": correct / len(rows) if rows else 0.0,
        "confusion_matrix": matrix,
        "matrix_labels": list(CLASS_LABELS),
        "per_class": per_class,
    }


def grouped_sessions(
    rows: list[DatasetRow], probabilities: list[list[float]]
) -> dict[str, list[tuple[DatasetRow, list[float]]]]:
    sessions: dict[str, list[tuple[DatasetRow, list[float]]]] = defaultdict(list)
    for row, scores in zip(rows, probabilities, strict=True):
        sessions[row.session_id].append((row, scores))
    for session_id, samples in sessions.items():
        labels = {label_for_row(row) for row, _ in samples}
        if len(labels) != 1:
            raise ValueError(f"session {session_id!r} contains multiple classes: {sorted(labels)}")
        samples.sort(key=lambda item: float(item[0].captured_at))
    return sessions


def target_session_metrics(
    rows: list[DatasetRow],
    probabilities: list[list[float]],
    target_label: str,
    threshold: float,
    *,
    required_hits: int = REQUIRED_CONSECUTIVE_HITS,
    observation_window_frames: int = OBSERVATION_WINDOW_FRAMES,
) -> dict:
    if required_hits <= 0 or observation_window_frames < required_hits:
        raise ValueError("observation window must contain the required hits")
    target_index = CLASS_INDEX[target_label]
    sessions = grouped_sessions(rows, probabilities)
    positive_sessions = 0
    detected_sessions = 0
    false_blocks = Counter({label: 0 for label in CLASS_LABELS if label != target_label})
    critical_false_frames = 0
    critical_false_sessions = 0
    detection_delays: list[float] = []

    for samples in sessions.values():
        actual_label = label_for_row(samples[0][0])
        recent_hits: list[bool] = []
        blocked_at: float | None = None
        critical_crossed = False
        for sample_index, (row, scores) in enumerate(samples):
            crossed = scores[target_index] >= threshold
            if row.is_critical == "true" and actual_label != target_label and crossed:
                critical_false_frames += 1
                critical_crossed = True
            recent_hits.append(crossed)
            if len(recent_hits) > observation_window_frames:
                recent_hits.pop(0)
            if blocked_at is None and sum(recent_hits) >= required_hits:
                blocked_at = sample_index * INFERENCE_INTERVAL_SECONDS
        if actual_label == target_label:
            positive_sessions += 1
            if blocked_at is not None:
                detected_sessions += 1
                detection_delays.append(blocked_at)
        elif blocked_at is not None:
            false_blocks[actual_label] += 1
        if critical_crossed:
            critical_false_sessions += 1

    delays = sorted(detection_delays)
    p95_index = max(0, math.ceil(0.95 * len(delays)) - 1) if delays else 0
    return {
        "threshold": threshold,
        "required_hits": required_hits,
        "observation_window_frames": observation_window_frames,
        "positive_sessions": positive_sessions,
        "detected_sessions": detected_sessions,
        "session_recall": detected_sessions / positive_sessions if positive_sessions else 0.0,
        "false_blocks": dict(false_blocks),
        "false_block_total": sum(false_blocks.values()),
        "critical_false_frames": critical_false_frames,
        "critical_false_sessions": critical_false_sessions,
        "p95_detection_seconds": delays[p95_index] if delays else math.inf,
    }


def threshold_candidates(probabilities: list[list[float]], target_label: str) -> list[float]:
    index = CLASS_INDEX[target_label]
    observed = {scores[index] for scores in probabilities}
    defaults = {0.5, 0.7, 0.8, 0.9, 0.95, 0.975, 0.99, 0.995, 0.999, 1.0}
    return sorted(observed | defaults)


def apply_probability_headroom_margin(score: float, margin: float) -> float:
    """Move a probability toward 1 by a fraction of its remaining headroom."""
    if not 0.0 <= score <= 1.0:
        raise ValueError("probability score must be between zero and one")
    if not 0.0 <= margin <= 1.0:
        raise ValueError("probability margin must be between zero and one")
    return score + ((1.0 - score) * margin)


def select_target_threshold(
    rows: list[DatasetRow], probabilities: list[list[float]], target_label: str
) -> tuple[float, dict]:
    target_index = CLASS_INDEX[target_label]
    passing: list[tuple[float, dict]] = []
    for threshold in threshold_candidates(probabilities, target_label):
        metrics = target_session_metrics(rows, probabilities, target_label, threshold)
        if (
            metrics["critical_false_frames"] == 0
            and metrics["false_block_total"] == 0
            and metrics["session_recall"] >= TARGET_SESSION_RECALL
        ):
            passing.append((threshold, metrics))
    if not passing:
        raise RuntimeError(
            f"no threshold gives {TARGET_SESSION_RECALL:.0%} {target_label} session recall "
            "with zero critical frames and zero false block events"
        )

    threshold = min(passing, key=lambda item: item[0])[0]
    critical_scores = [
        scores[target_index]
        for row, scores in zip(rows, probabilities, strict=True)
        if row.is_critical == "true" and label_for_row(row) != target_label
    ]
    if critical_scores:
        threshold = max(
            threshold,
            apply_probability_headroom_margin(
                max(critical_scores), CRITICAL_SCORE_MARGIN
            ),
        )
    metrics = target_session_metrics(rows, probabilities, target_label, threshold)
    if (
        metrics["critical_false_frames"] != 0
        or metrics["false_block_total"] != 0
        or metrics["session_recall"] < TARGET_SESSION_RECALL
    ):
        raise RuntimeError(f"the safety margin makes {target_label} miss the validation gate")
    return threshold, metrics


def calibrate_thresholds(
    rows: list[DatasetRow], probabilities: list[list[float]]
) -> tuple[dict[str, float], dict[str, dict]]:
    thresholds = {}
    metrics = {}
    for label in TARGET_LABELS:
        threshold, target_metrics = select_target_threshold(rows, probabilities, label)
        thresholds[label] = threshold
        metrics[label] = target_metrics
    return thresholds, metrics


def apply_threshold_floors(
    rows: list[DatasetRow],
    probabilities: list[list[float]],
    thresholds: dict[str, float],
    floors: dict[str, float],
) -> tuple[dict[str, float], dict[str, dict]]:
    """Keep a candidate at least as conservative as an incumbent policy."""
    missing = sorted(set(TARGET_LABELS) - set(floors))
    if missing:
        raise ValueError(f"threshold floor is missing targets: {missing}")
    promoted = {}
    metrics = {}
    for label in TARGET_LABELS:
        floor = float(floors[label])
        if not 0.0 <= floor <= 1.0:
            raise ValueError(f"invalid {label} threshold floor: {floor}")
        promoted[label] = max(thresholds[label], floor)
        metrics[label] = target_session_metrics(
            rows, probabilities, label, promoted[label]
        )
    return promoted, metrics


def best_effort_target_threshold(
    rows: list[DatasetRow], probabilities: list[list[float]], target_label: str
) -> tuple[float, dict]:
    candidates = [
        (
            threshold,
            target_session_metrics(rows, probabilities, target_label, threshold),
        )
        for threshold in threshold_candidates(probabilities, target_label)
    ]
    return min(
        candidates,
        key=lambda item: (
            item[1]["session_recall"] < TARGET_SESSION_RECALL,
            item[1]["p95_detection_seconds"] > MAX_P95_DETECTION_SECONDS,
            item[1]["critical_false_frames"],
            item[1]["false_block_total"],
            -item[0],
        ),
    )


def calibrate_thresholds_independently(
    rows: list[DatasetRow], probabilities: list[list[float]]
) -> tuple[dict[str, float], dict[str, dict], list[str]]:
    thresholds = {}
    metrics = {}
    errors = []
    for label in TARGET_LABELS:
        try:
            threshold, target_metrics = select_target_threshold(
                rows, probabilities, label
            )
        except RuntimeError as error:
            errors.append(str(error))
            threshold, target_metrics = best_effort_target_threshold(
                rows, probabilities, label
            )
        thresholds[label] = threshold
        metrics[label] = target_metrics
    return thresholds, metrics, errors


def quality_gate(metrics: dict[str, dict]) -> bool:
    return all(
        metrics[label]["session_recall"] >= TARGET_SESSION_RECALL
        and metrics[label]["false_block_total"] == 0
        and metrics[label]["critical_false_frames"] == 0
        and metrics[label]["p95_detection_seconds"] <= MAX_P95_DETECTION_SECONDS
        for label in TARGET_LABELS
    )


def quality_gate_failures(metrics: dict[str, dict]) -> list[str]:
    failures = []
    for label in TARGET_LABELS:
        values = metrics[label]
        if values["session_recall"] < TARGET_SESSION_RECALL:
            failures.append(
                f"{label} session recall {values['session_recall']:.3f} "
                f"is below {TARGET_SESSION_RECALL:.3f}"
            )
        if values["false_block_total"]:
            failures.append(f"{label} has {values['false_block_total']} false block events")
        if values["critical_false_frames"]:
            failures.append(
                f"{label} has {values['critical_false_frames']} critical false-positive frames"
            )
        if values["p95_detection_seconds"] > MAX_P95_DETECTION_SECONDS:
            failures.append(
                f"{label} p95 detection {values['p95_detection_seconds']}s "
                f"exceeds {MAX_P95_DETECTION_SECONDS}s"
            )
    return failures


def training_candidate_rank(metrics: dict[str, dict], loss: float) -> tuple:
    values = [metrics[label] for label in TARGET_LABELS]
    return (
        sum(value["critical_false_frames"] for value in values),
        sum(value["false_block_total"] for value in values),
        -min(value["session_recall"] for value in values),
        -sum(value["session_recall"] for value in values),
        max(value["p95_detection_seconds"] for value in values),
        loss,
    )


def snapshot_state_dict(model) -> dict:
    return {key: value.detach().cpu().clone() for key, value in model.state_dict().items()}


def train(args: argparse.Namespace) -> None:
    torch, nn, DataLoader, _ = torch_modules()
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    manifest = Path(args.manifest).resolve()
    rows = validate_manifest(manifest)
    training = rows_for_split(rows, "train")
    validation = rows_for_split(rows, "validation")
    device = resolve_device(args.device)
    model = build_model().to(device)
    if args.instagram_content_loss_weight <= 0:
        raise ValueError("Instagram content loss weight must be positive")
    weights = training_sample_weights(training, critical_weight=args.critical_weight)
    loader = DataLoader(
        make_dataset(training, manifest.parent, augment=True, weights=weights),
        batch_size=args.batch_size,
        shuffle=True,
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate, weight_decay=1e-4)
    loss_function = nn.CrossEntropyLoss(reduction="none")
    best: tuple[tuple, dict, dict] | None = None

    for epoch in range(1, args.epochs + 1):
        model.train()
        total_loss = 0.0
        for (
            images,
            app_targets,
            youtube_targets,
            instagram_targets,
            youtube_mask,
            instagram_mask,
            sample_weights,
        ) in loader:
            images = images.to(device)
            app_targets = app_targets.to(device)
            youtube_targets = youtube_targets.to(device)
            instagram_targets = instagram_targets.to(device)
            youtube_mask = youtube_mask.to(device)
            instagram_mask = instagram_mask.to(device)
            sample_weights = sample_weights.to(device)
            optimizer.zero_grad(set_to_none=True)
            app_logits, youtube_logits, instagram_logits = model(images)
            per_sample_loss = loss_function(app_logits, app_targets)
            per_sample_loss += loss_function(youtube_logits, youtube_targets) * youtube_mask
            per_sample_loss += (
                loss_function(instagram_logits, instagram_targets)
                * instagram_mask
                * args.instagram_content_loss_weight
            )
            loss = (per_sample_loss * sample_weights).mean()
            loss.backward()
            optimizer.step()
            total_loss += float(loss.detach().cpu())

        validation_probabilities = predict_rows(model, validation, manifest.parent, device)
        thresholds, session_results, _ = calibrate_thresholds_independently(
            validation, validation_probabilities
        )
        epoch_loss = total_loss / max(len(loader), 1)
        rank = training_candidate_rank(session_results, epoch_loss)
        if best is None or rank < best[0]:
            best = (
                rank,
                snapshot_state_dict(model),
                {"epoch": epoch, "thresholds": thresholds, "session": session_results},
            )
        summary = " ".join(
            f"{label}={session_results[label]['session_recall']:.3f}"
            f"/fp{session_results[label]['false_block_total']}"
            f"/critical{session_results[label]['critical_false_frames']}"
            for label in TARGET_LABELS
        )
        print(f"epoch={epoch:03d} loss={epoch_loss:.4f} {summary}")

    assert best is not None
    model.load_state_dict(best[1])
    validation_probabilities = predict_rows(model, validation, manifest.parent, device)
    thresholds, session_results, calibration_errors = calibrate_thresholds_independently(
        validation, validation_probabilities
    )
    validation_metrics = {
        "frames": frame_metrics(validation, validation_probabilities),
        "sessions": session_results,
    }
    failures = quality_gate_failures(session_results)
    failures[0:0] = calibration_errors
    passed = not failures
    report = {
        "status": "passed" if passed else "failed",
        "reason": None if passed else "; ".join(failures),
        "selected_epoch": best[2]["epoch"],
        "training": {
            "epochs": args.epochs,
            "batch_size": args.batch_size,
            "seed": args.seed,
            "device": str(device),
            "architecture": ARCHITECTURE,
            "input_width": INPUT_WIDTH,
            "input_height": INPUT_HEIGHT,
            "critical_weight": args.critical_weight,
            "instagram_content_loss_weight": args.instagram_content_loss_weight,
        },
        "thresholds": thresholds,
        "validation": validation_metrics,
    }
    if args.report:
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print(f"saved validation report {report_path}")
    if not passed:
        print(json.dumps(report, indent=2))
        raise RuntimeError(f"validation quality gate failed: {report['reason']}")
    checkpoint = {
        "state_dict": snapshot_state_dict(model),
        "app_labels": list(APP_LABELS),
        "youtube_content_labels": list(YOUTUBE_CONTENT_LABELS),
        "instagram_content_labels": list(INSTAGRAM_CONTENT_LABELS),
        "input_width": INPUT_WIDTH,
        "input_height": INPUT_HEIGHT,
        "architecture": ARCHITECTURE,
        "thresholds": thresholds,
        "inference_interval_seconds": INFERENCE_INTERVAL_SECONDS,
        "required_consecutive_hits": REQUIRED_CONSECUTIVE_HITS,
        "observation_window_frames": OBSERVATION_WINDOW_FRAMES,
        "critical_score_margin": CRITICAL_SCORE_MARGIN,
        "critical_score_margin_policy": "probability-headroom-fraction",
        "critical_weight": args.critical_weight,
        "instagram_content_loss_weight": args.instagram_content_loss_weight,
        "validation_metrics": validation_metrics,
        "selected_epoch": best[2]["epoch"],
        "model_version": args.model_version,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(checkpoint, output)
    print(json.dumps(validation_metrics, indent=2))
    print(f"saved {output}")


def load_checkpoint(path: Path):
    torch, _, _, _ = torch_modules()
    checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    expected_labels = {
        "app_labels": list(APP_LABELS),
        "youtube_content_labels": list(YOUTUBE_CONTENT_LABELS),
        "instagram_content_labels": list(INSTAGRAM_CONTENT_LABELS),
    }
    if any(checkpoint.get(key) != labels for key, labels in expected_labels.items()):
        raise ValueError("checkpoint head labels do not match hierarchical SurfaceDetector v3")
    if checkpoint.get("architecture") != ARCHITECTURE:
        raise ValueError(
            f"checkpoint architecture {checkpoint.get('architecture')!r} "
            f"does not match {ARCHITECTURE!r}"
        )
    model = build_model()
    model.load_state_dict(checkpoint["state_dict"])
    model.eval()
    return model, checkpoint


def evaluation_report(
    rows: list[DatasetRow], probabilities: list[list[float]], thresholds: dict[str, float]
) -> dict:
    return {
        "frames": frame_metrics(rows, probabilities),
        "sessions": {
            label: target_session_metrics(rows, probabilities, label, thresholds[label])
            for label in TARGET_LABELS
        },
    }


def evaluate(args: argparse.Namespace) -> None:
    manifest = Path(args.manifest).resolve()
    all_rows = validate_manifest(manifest)
    rows = rows_for_split(all_rows, args.split)
    model, checkpoint = load_checkpoint(Path(args.checkpoint))
    probabilities = predict_rows(model, rows, manifest.parent)
    report = evaluation_report(rows, probabilities, checkpoint["thresholds"])
    print(json.dumps(report, indent=2))
    if not quality_gate(report["sessions"]):
        raise SystemExit(2)


def retune_policy(args: argparse.Namespace) -> None:
    """Recalibrate a checkpoint for the current temporal voting policy."""
    torch, _, _, _ = torch_modules()
    manifest = Path(args.manifest).resolve()
    all_rows = validate_manifest(manifest)
    validation = rows_for_split(all_rows, "validation")
    model, checkpoint = load_checkpoint(Path(args.checkpoint))
    probabilities = predict_rows(model, validation, manifest.parent)
    thresholds, session_results = calibrate_thresholds(validation, probabilities)
    threshold_floor = None
    if getattr(args, "threshold_floor_checkpoint", None):
        _, floor_checkpoint = load_checkpoint(Path(args.threshold_floor_checkpoint))
        thresholds, session_results = apply_threshold_floors(
            validation,
            probabilities,
            thresholds,
            floor_checkpoint["thresholds"],
        )
        threshold_floor = {
            "source_checkpoint": str(args.threshold_floor_checkpoint),
            "model_version": floor_checkpoint["model_version"],
            "thresholds": floor_checkpoint["thresholds"],
            "policy": "maximum-of-validation-calibrated-and-incumbent",
        }
    validation_metrics = {
        "frames": frame_metrics(validation, probabilities),
        "sessions": session_results,
    }
    failures = quality_gate_failures(session_results)
    report = {
        "status": "passed" if not failures else "failed",
        "reason": None if not failures else "; ".join(failures),
        "source_checkpoint": str(args.checkpoint),
        "model_version": args.model_version,
        "temporal_policy": {
            "required_hits": REQUIRED_CONSECUTIVE_HITS,
            "observation_window_frames": OBSERVATION_WINDOW_FRAMES,
        },
        "thresholds": thresholds,
        "threshold_floor": threshold_floor,
        "validation": validation_metrics,
    }
    if args.report:
        report_path = Path(args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print(f"saved validation report {report_path}")
    if failures:
        raise RuntimeError(f"validation quality gate failed: {report['reason']}")
    promoted = dict(checkpoint)
    promoted.update(
        thresholds=thresholds,
        validation_metrics=validation_metrics,
        required_consecutive_hits=REQUIRED_CONSECUTIVE_HITS,
        observation_window_frames=OBSERVATION_WINDOW_FRAMES,
        model_version=args.model_version,
        threshold_floor=threshold_floor,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(promoted, output)
    print(json.dumps(validation_metrics, indent=2))
    print(f"saved {output}")


def export(args: argparse.Namespace) -> None:
    import coremltools as ct

    torch, nn, _, _ = torch_modules()
    model, checkpoint = load_checkpoint(Path(args.checkpoint))

    class ProbabilityModel(nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image):
            app_logits, youtube_logits, instagram_logits = self.inner(image)
            return (
                torch.softmax(app_logits, dim=1),
                torch.softmax(youtube_logits, dim=1),
                torch.softmax(instagram_logits, dim=1),
            )

    wrapped = ProbabilityModel(model).eval()
    example = torch.zeros(1, 3, INPUT_HEIGHT, INPUT_WIDTH)
    traced = torch.jit.trace(wrapped, example)
    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.ImageType(
                name="image",
                shape=example.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1 / 255.0,
            )
        ],
        outputs=[
            ct.TensorType(name="appProbabilities"),
            ct.TensorType(name="youtubeContentProbabilities"),
            ct.TensorType(name="instagramContentProbabilities"),
        ],
    )
    package = Path(args.package)
    if package.exists():
        shutil.rmtree(package)
    converted.save(package)
    metadata = {
        "modelVersion": checkpoint["model_version"],
        "appLabels": checkpoint["app_labels"],
        "youtubeContentLabels": checkpoint["youtube_content_labels"],
        "instagramContentLabels": checkpoint["instagram_content_labels"],
        "inputWidth": checkpoint["input_width"],
        "inputHeight": checkpoint["input_height"],
        "architecture": checkpoint["architecture"],
        "confidenceThresholds": checkpoint["thresholds"],
        "inferenceIntervalSeconds": checkpoint["inference_interval_seconds"],
        "requiredConsecutiveHits": checkpoint["required_consecutive_hits"],
        "observationWindowFrames": checkpoint.get(
            "observation_window_frames", checkpoint["required_consecutive_hits"]
        ),
        "criticalScoreMargin": checkpoint["critical_score_margin"],
        "criticalScoreMarginPolicy": checkpoint["critical_score_margin_policy"],
        "computePrecision": "float32",
        "validation": checkpoint["validation_metrics"],
    }
    if checkpoint.get("threshold_floor"):
        metadata["thresholdFloor"] = checkpoint["threshold_floor"]
    metadata_path = Path(args.metadata)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"saved {package} and {metadata_path}")


def decision_signature(report: dict) -> dict:
    return {
        label: {
            "detected_sessions": report["sessions"][label]["detected_sessions"],
            "false_blocks": report["sessions"][label]["false_blocks"],
            "critical_false_frames": report["sessions"][label]["critical_false_frames"],
        }
        for label in TARGET_LABELS
    }


def verify_export(args: argparse.Namespace) -> None:
    import coremltools as ct

    manifest = Path(args.manifest).resolve()
    all_rows = validate_manifest(manifest)
    rows = rows_for_split(all_rows, args.split)
    torch_model, checkpoint = load_checkpoint(Path(args.checkpoint))
    torch_heads = predict_heads(torch_model, rows, manifest.parent)
    torch_probabilities = joint_probabilities(torch_heads)
    coreml_model = ct.models.MLModel(args.package, compute_units=ct.ComputeUnit.CPU_ONLY)
    coreml_heads: dict[str, list[list[float]]] = {
        "app": [],
        "youtube_content": [],
        "instagram_content": [],
    }
    for row in rows:
        image = Image.fromarray(resized_rgb(str(manifest.parent / row.path)).copy(), mode="RGB")
        prediction = coreml_model.predict({"image": image})
        for key, output_name in (
            ("app", "appProbabilities"),
            ("youtube_content", "youtubeContentProbabilities"),
            ("instagram_content", "instagramContentProbabilities"),
        ):
            scores = np.asarray(prediction[output_name]).reshape(-1)
            coreml_heads[key].append([float(score) for score in scores])
    coreml_probabilities = joint_probabilities(coreml_heads)

    differences = [
        abs(left - right)
        for key in ("app", "youtube_content", "instagram_content")
        for torch_scores, coreml_scores in zip(torch_heads[key], coreml_heads[key], strict=True)
        for left, right in zip(torch_scores, coreml_scores, strict=True)
    ]
    top_one_mismatches = sum(
        int(np.argmax(torch_scores) != np.argmax(coreml_scores))
        for torch_scores, coreml_scores in zip(
            torch_probabilities, coreml_probabilities, strict=True
        )
    )
    torch_report = evaluation_report(rows, torch_probabilities, checkpoint["thresholds"])
    coreml_report = evaluation_report(rows, coreml_probabilities, checkpoint["thresholds"])
    report = {
        "max_absolute_probability_difference": max(differences, default=0.0),
        "top_one_mismatches": top_one_mismatches,
        "torch_decisions": decision_signature(torch_report),
        "coreml_decisions": decision_signature(coreml_report),
    }
    print(json.dumps(report, indent=2))
    if (
        report["max_absolute_probability_difference"] > args.tolerance
        or top_one_mismatches != 0
        or report["torch_decisions"] != report["coreml_decisions"]
    ):
        raise SystemExit(2)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    command = commands.add_parser("train", help="train and calibrate the hierarchical model")
    command.add_argument("manifest")
    command.add_argument("output")
    command.add_argument("--epochs", type=int, default=60)
    command.add_argument("--batch-size", type=int, default=16)
    command.add_argument("--learning-rate", type=float, default=1e-3)
    command.add_argument("--seed", type=int, default=7)
    command.add_argument("--device", choices=("auto", "cpu", "mps"), default="auto")
    command.add_argument("--critical-weight", type=float, default=CRITICAL_WEIGHT)
    command.add_argument("--instagram-content-loss-weight", type=float, default=1.0)
    command.add_argument("--model-version", default="surface-hierarchical-v3")
    command.add_argument("--report", help="write a validation gate report, including failures")
    command.set_defaults(function=train)

    command = commands.add_parser("evaluate", help="evaluate frame and session quality gates")
    command.add_argument("manifest")
    command.add_argument("checkpoint")
    command.add_argument("--split", choices=sorted(EVALUATION_SPLITS), default="test")
    command.set_defaults(function=evaluate)

    command = commands.add_parser(
        "retune-policy", help="recalibrate a checkpoint for the current temporal policy"
    )
    command.add_argument("manifest")
    command.add_argument("checkpoint")
    command.add_argument("output")
    command.add_argument("--model-version", required=True)
    command.add_argument("--report")
    command.add_argument(
        "--threshold-floor-checkpoint",
        help="keep target thresholds at least as high as this incumbent checkpoint",
    )
    command.set_defaults(function=retune_policy)

    command = commands.add_parser("export", help="convert a checkpoint to an iOS 16 ML Program")
    command.add_argument("checkpoint")
    command.add_argument("package")
    command.add_argument("metadata")
    command.set_defaults(function=export)

    command = commands.add_parser("verify-export", help="compare PyTorch and Core ML predictions")
    command.add_argument("manifest")
    command.add_argument("checkpoint")
    command.add_argument("package")
    command.add_argument("--split", choices=sorted(EVALUATION_SPLITS), default="test")
    command.add_argument("--tolerance", type=float, default=0.01)
    command.set_defaults(function=verify_export)
    return root


def main() -> None:
    args = parser().parse_args()
    args.function(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
