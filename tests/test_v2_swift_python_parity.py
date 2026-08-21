from scripts.check_v2_swift_python_parity import markdown_report
from scripts.pitch_tournament_engines import _ExperimentalHarmonicJumpGate, _ShortV2GapBridge


def test_v2_parity_report_identifies_the_python_swift_boundary():
    report = {
        "verified": True,
        "frequency_tolerance_cents": 1.0,
        "confidence_tolerance": 0.01,
        "cases": [{
            "source": "fixture.wav", "python_frames": 1, "swift_frames": 1,
            "difference_count": 0, "first_difference": None,
        }],
    }

    rendered = markdown_report(report)

    assert "Python / Swift" in rendered
    assert "Geçiş kanıtı" in rendered


def test_v2_parity_report_labels_cpp_as_production_parity():
    report = {
        "verified": True,
        "left_implementation": "cpp",
        "comparison": "Üretim paritesi",
        "frequency_tolerance_cents": 1.0,
        "confidence_tolerance": 0.01,
        "cases": [{
            "source": "fixture.wav", "python_frames": 1, "swift_frames": 1,
            "difference_count": 0, "first_difference": None,
        }],
    }

    rendered = markdown_report(report)

    assert "C++ / Swift" in rendered
    assert "Üretim paritesi" in rendered


def test_v2_mirror_holds_one_downward_octave_hop():
    gate = _ExperimentalHarmonicJumpGate()

    assert gate.filter((440.0, 0.9)) == (440.0, 0.9)
    assert gate.filter((220.0, 0.9)) == (440.0, 0.55)
    assert gate.filter((220.0, 0.9)) == (220.0, 0.9)


def test_v2_gap_bridge_restores_only_a_returning_contour():
    bridge = _ShortV2GapBridge()

    assert bridge.resolve((440.0, 0.9), 0.0, True) == [(0.0, 440.0, 0.9)]
    assert bridge.resolve(None, 0.01, True) == []
    assert bridge.resolve((441.0, 0.9), 0.02, True) == [
        (0.01, 440.0, 0.9), (0.02, 441.0, 0.9)
    ]


def test_v2_gap_bridge_does_not_restart_after_seven_frames():
    bridge = _ShortV2GapBridge()
    assert bridge.resolve((440.0, 0.9), 0.0, True)
    for index in range(1, 10):
        assert bridge.resolve(None, index * 0.01, True) == []
    assert bridge.resolve((440.0, 0.9), 0.10, True) == [(0.10, 440.0, 0.9)]


def test_v2_gap_bridge_hard_rms_gate_forgets_the_old_contour():
    bridge = _ShortV2GapBridge()
    assert bridge.resolve((440.0, 0.9), 0.0, True)
    assert bridge.resolve(None, 0.01, False) == []
    assert bridge.resolve(None, 0.02, True) == []
    assert bridge.resolve((440.0, 0.9), 0.03, True) == [(0.03, 440.0, 0.9)]
