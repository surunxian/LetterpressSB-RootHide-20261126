#!/usr/bin/env python3
"""Exactly one draw-call suppression in a private copy of the pinned Vortex package."""
import hashlib
from pathlib import Path

VIEW = 'Sources/Vortex/Views/VortexView.swift'
ORIGINAL_VIEW_SHA256 = '8050f795edae1e23dcc742334d68d26fd4c93ca93a6b4d850a8ad75a9edfcb38'
ORIGINAL_CALL = '                draw(particleSystem, into: context, at: size)\n'
ISOLATION_LINE = '                // Letterpress isolate4: deliberately omit per-particle draw; keep Canvas and update.\n'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def isolate_draw(local: Path, original_swift_sha256: dict) -> dict:
    """Retain all 26 original sources except one exactly reversible call-site edit.

    Suppression is unconditional for the entire experiment. There is no wake
    timer, state gate, frame-rate change, simulation edit or hidden pause patch.
    Keeping the Canvas/update source is not a runtime cadence guarantee.
    """
    if len(original_swift_sha256) != 26 or original_swift_sha256.get(VIEW) != ORIGINAL_VIEW_SHA256:
        raise ValueError('Unexpected pinned Vortex source inventory')
    for name, expected in original_swift_sha256.items():
        if digest((local / name).read_bytes()) != expected:
            raise ValueError('Unclean upstream source before draw isolation: ' + name)
    target = local / VIEW
    original = target.read_bytes()
    old, new = ORIGINAL_CALL.encode(), ISOLATION_LINE.encode()
    if original.count(old) != 1 or new in original:
        raise ValueError('Expected exactly one original primary draw invocation')
    adapted = original.replace(old, new, 1)
    if adapted.count(new) != 1 or adapted.replace(new, old, 1) != original:
        raise ValueError('Draw-only reverse proof failed')
    required = [b'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate)))',
                b'Canvas { context, size in',
                b'particleSystem.update(date: timeline.date, drawSize: size)',
                b'private func draw(', b'contextCopy.draw(symbol, at: .zero)']
    if not all(adapted.count(x) == original.count(x) and original.count(x) > 0 for x in required):
        raise ValueError('Original Timeline/Canvas/update/draw-function structure changed')
    target.write_bytes(adapted)
    compiled = {name: digest((local / name).read_bytes()) for name in original_swift_sha256}
    changed = [name for name in compiled if compiled[name] != original_swift_sha256[name]]
    if changed != [VIEW]:
        raise ValueError('Unexpected renderer mutation set: ' + repr(changed))
    return {'scope': 'whole-test-interval', 'update_retained': True,
            'timeline_and_canvas_retained': True, 'suppressed_call_count': 1,
            'view_original_sha256': digest(original), 'view_adapted_sha256': digest(adapted),
            'reverse_restores_upstream': True}
