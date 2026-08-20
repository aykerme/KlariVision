from scripts.check_vpm_swift_cpp_parity import TraceFrame, compare_traces
from scripts.pitch_tournament_engines import _bridge_short_vpm_gaps


def test_trace_comparison_accepts_small_numeric_differences():
    cpp = [TraceFrame(0.1, 440.0, 0.90)]
    swift = [TraceFrame(0.1, 440.1, 0.895)]

    assert compare_traces(cpp, swift) == []


def test_trace_comparison_reports_voicing_before_frequency():
    cpp = [TraceFrame(0.1, 440.0, 0.90), TraceFrame(0.2, 440.0, 0.90)]
    swift = [TraceFrame(0.2, 220.0, 0.90)]

    differences = compare_traces(cpp, swift)

    assert [difference.kind for difference in differences] == ["voicing", "frequency"]
    assert differences[0].time == 0.1
    assert differences[1].cents == 1_200


def test_short_gap_is_not_bridged_across_a_hard_signal_gate():
    hop = 0.01
    frames = [(0.0, 440.0, 0.9), (0.04, 441.0, 0.9)]

    bridged = _bridge_short_vpm_gaps(frames, hop, blocked_times={0.02})

    assert bridged == frames
