from dataclasses import replace

import pytest

from scripts import surface_ml
from scripts.realtime_dataset import DatasetRow


def row(
    session: str,
    app: str,
    content: str,
    *,
    index: int = 0,
    split: str = "validation",
    critical: bool = False,
) -> DatasetRow:
    return DatasetRow(
        path=f"frames/{app}/{content}/{session}/{index}.png",
        app=app,
        content=content,
        is_critical=str(critical).lower(),
        session_id=session,
        split=split,
        captured_at=float(index),
        device_model="unknown",
        os_version="unknown",
        app_version="unknown",
        orientation="portrait",
        source_batch="test",
    )


def scores(**values: float) -> list[float]:
    output = [0.0] * len(surface_ml.CLASS_LABELS)
    for label, value in values.items():
        output[surface_ml.CLASS_INDEX[label]] = value
    return output


def test_class_mapping_is_stable():
    assert surface_ml.CLASS_LABELS == (
        "youtube_shorts",
        "youtube_normal",
        "instagram_reels",
        "instagram_stories",
        "instagram_normal",
        "other_app",
    )
    assert surface_ml.label_for_row(row("reels", "instagram", "reels")) == "instagram_reels"
    assert (
        surface_ml.label_for_row(row("stories", "instagram", "stories"))
        == "instagram_stories"
    )


def test_unassigned_rows_are_not_selected_for_training():
    training = row("train", "youtube", "shorts", split="train")
    unassigned = replace(training, session_id="pending", split="unassigned")

    assert surface_ml.rows_for_split(
        [training, unassigned], "train", require_all_classes=False
    ) == [training]


def test_split_requires_every_surface_class():
    rows = [row("shorts", "youtube", "shorts", split="train")]

    with pytest.raises(ValueError, match="missing classes"):
        surface_ml.rows_for_split(rows, "train")


def test_critical_weight_multiplies_balanced_class_weight():
    rows = [
        row("shorts", "youtube", "shorts", split="train"),
        row("youtube", "youtube", "normal", split="train", critical=True),
        row("reels", "instagram", "reels", split="train"),
        row("stories", "instagram", "stories", split="train"),
        row("instagram", "instagram", "normal", split="train"),
        row("other", "other", "normal", split="train"),
    ]

    assert surface_ml.training_sample_weights(rows) == [1.0, 5.0, 1.0, 1.0, 1.0, 1.0]
    assert surface_ml.training_sample_weights(rows, critical_weight=10.0) == [
        1.0,
        10.0,
        1.0,
        1.0,
        1.0,
        1.0,
    ]


def test_critical_weight_must_be_positive():
    rows = [row("shorts", "youtube", "shorts", split="train")]

    with pytest.raises(ValueError, match="critical weight must be positive"):
        surface_ml.training_sample_weights(rows, critical_weight=0)


def test_three_consecutive_frames_detect_at_half_second():
    rows = [row("shorts", "youtube", "shorts", index=index) for index in range(4)]
    probabilities = [scores(youtube_shorts=0.9) for _ in rows]

    metrics = surface_ml.target_session_metrics(
        rows, probabilities, "youtube_shorts", threshold=0.8
    )

    assert metrics["detected_sessions"] == 1
    assert metrics["session_recall"] == 1.0
    assert metrics["p95_detection_seconds"] == 0.5


def test_three_of_five_detects_interrupted_reels_evidence():
    rows = [row("reels", "instagram", "reels", index=index) for index in range(5)]
    probabilities = [
        scores(instagram_reels=value) for value in (0.1, 0.95, 0.96, 0.1, 0.97)
    ]

    metrics = surface_ml.target_session_metrics(
        rows, probabilities, "instagram_reels", threshold=0.9
    )

    assert metrics["detected_sessions"] == 1
    assert metrics["p95_detection_seconds"] == 1.0


def test_thresholds_are_calibrated_independently():
    rows = []
    probabilities = []
    fixtures = [
        ("shorts", "youtube", "shorts", False, scores(youtube_shorts=0.8)),
        ("youtube", "youtube", "normal", True, scores(youtube_shorts=0.6)),
        ("reels", "instagram", "reels", False, scores(instagram_reels=0.65)),
        (
            "stories",
            "instagram",
            "stories",
            False,
            scores(instagram_stories=0.75),
        ),
        (
            "instagram",
            "instagram",
            "normal",
            True,
            scores(instagram_reels=0.52, instagram_stories=0.55),
        ),
        (
            "other",
            "other",
            "normal",
            True,
            scores(youtube_shorts=0.1, instagram_reels=0.1, instagram_stories=0.1),
        ),
    ]
    for session, app, content, critical, probability in fixtures:
        for index in range(3):
            rows.append(row(session, app, content, index=index, critical=critical))
            probabilities.append(probability)

    thresholds, metrics = surface_ml.calibrate_thresholds(rows, probabilities)

    assert thresholds == {
        "youtube_shorts": 0.7,
        "instagram_reels": 0.65,
        "instagram_stories": 0.7,
    }
    assert metrics["youtube_shorts"]["false_block_total"] == 0
    assert metrics["instagram_reels"]["false_block_total"] == 0
    assert metrics["instagram_stories"]["false_block_total"] == 0


def test_failed_target_does_not_discard_successful_target_calibration():
    rows = []
    probabilities = []
    fixtures = [
        ("shorts", "youtube", "shorts", False, scores(youtube_shorts=0.9)),
        (
            "youtube",
            "youtube",
            "normal",
            True,
            scores(youtube_shorts=0.1, instagram_reels=0.9),
        ),
        ("reels", "instagram", "reels", False, scores(instagram_reels=0.8)),
        (
            "stories",
            "instagram",
            "stories",
            False,
            scores(instagram_stories=0.85),
        ),
    ]
    for session, app, content, critical, probability in fixtures:
        for index in range(3):
            rows.append(row(session, app, content, index=index, critical=critical))
            probabilities.append(probability)

    thresholds, metrics, errors = surface_ml.calibrate_thresholds_independently(
        rows, probabilities
    )

    assert thresholds["youtube_shorts"] == 0.5
    assert metrics["youtube_shorts"]["session_recall"] == 1.0
    assert metrics["youtube_shorts"]["critical_false_frames"] == 0
    assert len(errors) == 1
    assert "instagram_reels" in errors[0]


def test_threshold_rejects_every_individual_critical_frame():
    rows = [row("shorts", "youtube", "shorts", index=index) for index in range(3)]
    rows += [
        row("critical", "instagram", "normal", index=index, critical=True)
        for index in range(3)
    ]
    probabilities = [scores(youtube_shorts=0.9) for _ in range(3)]
    probabilities += [
        scores(youtube_shorts=0.85),
        scores(youtube_shorts=0.1),
        scores(youtube_shorts=0.1),
    ]

    threshold, metrics = surface_ml.select_target_threshold(
        rows, probabilities, "youtube_shorts"
    )

    assert threshold > 0.85
    assert metrics["critical_false_frames"] == 0
    assert metrics["session_recall"] == 1.0


def test_probability_margin_preserves_headroom_near_one():
    assert surface_ml.apply_probability_headroom_margin(0.99, 0.025) == pytest.approx(
        0.99025
    )


def test_threshold_floors_preserve_incumbent_safety_policy():
    rows = []
    probabilities = []
    targets = (
        ("shorts", "youtube", "shorts", "youtube_shorts"),
        ("reels", "instagram", "reels", "instagram_reels"),
        ("stories", "instagram", "stories", "instagram_stories"),
    )
    for session, app, content, label in targets:
        for index in range(3):
            rows.append(row(session, app, content, index=index))
            probabilities.append(scores(**{label: 0.9}))

    thresholds, metrics = surface_ml.apply_threshold_floors(
        rows,
        probabilities,
        {label: 0.5 for label in surface_ml.TARGET_LABELS},
        {label: 0.8 for label in surface_ml.TARGET_LABELS},
    )

    assert thresholds == {label: 0.8 for label in surface_ml.TARGET_LABELS}
    assert all(value["session_recall"] == 1.0 for value in metrics.values())


def test_model_preserves_spatial_grid_and_outputs_hierarchical_logits():
    torch, _, _, _ = surface_ml.torch_modules()
    model = surface_ml.build_model().eval()

    with torch.no_grad():
        app, youtube, instagram = model(
            torch.zeros(1, 3, surface_ml.INPUT_HEIGHT, surface_ml.INPUT_WIDTH)
        )

    assert app.shape == (1, 3)
    assert youtube.shape == (1, 2)
    assert instagram.shape == (1, 3)
    assert model.pool.output_size == (6, 3)


def test_joint_probabilities_multiply_app_and_conditional_content():
    heads = {
        "app": [[0.6, 0.3, 0.1]],
        "youtube_content": [[0.75, 0.25]],
        "instagram_content": [[0.2, 0.3, 0.5]],
    }

    probabilities = surface_ml.joint_probabilities(heads)[0]

    assert probabilities == pytest.approx([0.45, 0.15, 0.06, 0.09, 0.15, 0.1])
    assert sum(probabilities) == pytest.approx(1.0)


def test_snapshot_state_dict_does_not_change_with_model():
    torch, _, _, _ = surface_ml.torch_modules()
    model = torch.nn.Linear(1, 1)
    snapshot = surface_ml.snapshot_state_dict(model)

    with torch.no_grad():
        model.weight.add_(1)

    assert not torch.equal(snapshot["weight"], model.state_dict()["weight"])


def test_quality_gate_failures_explain_every_failed_constraint():
    metrics = {
        label: {
            "session_recall": 0.0,
            "false_block_total": 1,
            "critical_false_frames": 2,
            "p95_detection_seconds": 2.25,
        }
        for label in surface_ml.TARGET_LABELS
    }

    failures = surface_ml.quality_gate_failures(metrics)

    assert len(failures) == 12
    assert any("youtube_shorts session recall" in failure for failure in failures)
    assert any("instagram_reels p95 detection" in failure for failure in failures)
