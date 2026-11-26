#!/usr/bin/env python3
"""Bound only discontinuous frame gaps and explicitly pause hidden Vortex canvases."""
from pathlib import Path
import hashlib

ORIGINALS = {
    'Sources/Vortex/Views/VortexView.swift': '8050f795edae1e23dcc742334d68d26fd4c93ca93a6b4d850a8ad75a9edfcb38',
    'Sources/Vortex/System/VortexSystem-Behavior.swift': 'a1b85697b654d37760c97bae8ad0ea2c3df2a6859adebeffc0a19f1cc8493d96',
    'Sources/Vortex/Views/VortexViewReader.swift': '6910bae0ba1d59d80ed8cad33cc201cf47e6cb8435b797b31271b47d1721f76f',
}
LIFECYCLE_SWIFT = '''// LetterpressSB lifecycle adapter; upstream visual drawing is unchanged.
import SwiftUI

private struct LPSBVortexRenderingPausedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var lpsbVortexRenderingPaused: Bool {
        get { self[LPSBVortexRenderingPausedKey.self] }
        set { self[LPSBVortexRenderingPausedKey.self] = newValue }
    }
}

// A stopped display timeline is not simulation time owed on the next frame.
// Preserve ordinary frames exactly, including supported low refresh rates.
// Discard gaps >250ms, reversed wall-clock steps and non-finite intervals.
func lpsbBoundedFrameDelta(_ elapsed: Double) -> Double {
    elapsed.isFinite && elapsed >= 0 && elapsed <= 0.25 ? elapsed : 1.0 / 60.0
}
'''

def digest(data):
    return hashlib.sha256(data).hexdigest()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Unrecognised pinned Vortex source; no broad patch permitted')
    return text.replace(old, new)

def adapt(local: Path):
    originals = {}
    for name, sha in ORIGINALS.items():
        data = (local / name).read_bytes()
        if digest(data) != sha:
            raise RuntimeError('Pinned Vortex lifecycle input hash mismatch: ' + name)
        originals[name] = data.decode()
    view_name, behavior_name, reader_name = ORIGINALS
    view = replace_once(originals[view_name],
        '    public var targetFrameRate: Int\n',
        '    public var targetFrameRate: Int\n\n'
        '    @Environment(\\.lpsbVortexRenderingPaused) private var lpsbRenderingPaused\n')
    view = replace_once(view,
        'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate)))',
        'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate), paused: lpsbRenderingPaused))')
    view = replace_once(view, '            Canvas { context, size in\n',
        '            Canvas { context, size in\n'
        '                // Hidden updates may still invalidate Canvas; do not simulate or draw.\n'
        '                guard !lpsbRenderingPaused else { return }\n')
    behavior = replace_once(originals[behavior_name],
        '        let delta = currentTimeInterval - lastUpdate\n',
        '        let delta = lpsbBoundedFrameDelta(currentTimeInterval - lastUpdate)\n')
    reader = replace_once(originals[reader_name],
        '    @State private var nearestVortexSystem: VortexSystem?\n',
        '    @State private var nearestVortexSystem: VortexSystem?\n'
        '    @Environment(\\.lpsbVortexRenderingPaused) private var lpsbRenderingPaused\n')
    reader = replace_once(reader,
        '            nearestVortexSystem?.burst()\n',
        '            // Subtitle changes must not accumulate hidden burst particles.\n'
        '            guard !lpsbRenderingPaused else { return }\n'
        '            nearestVortexSystem?.burst()\n')
    outputs = {view_name: view, behavior_name: behavior, reader_name: reader,
        'Sources/Vortex/LPSBVortexRendering.swift': LIFECYCLE_SWIFT}
    for name, text in outputs.items():
        (local / name).write_text(text)
    return {'original_sha256': ORIGINALS,
        'adapted_sha256': {name: digest(text.encode()) for name, text in outputs.items()},
        'normal_frame_interval_unchanged_seconds': [0, 0.25],
        'discontinuous_frame_delta_seconds': 1 / 60,
        'timeline_paused_when_hidden': True,
        'canvas_simulation_and_drawing_guarded': True,
        'visual_draw_function_unchanged': True,
        'device_tested': False}
