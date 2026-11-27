#!/usr/bin/env python3
"""Reversible, one-factor Timeline schedule isolation for pinned Vortex."""
from pathlib import Path
import hashlib

VIEW = 'Sources/Vortex/Views/VortexView.swift'
ORIGINAL_VIEW_SHA256 = '8050f795edae1e23dcc742334d68d26fd4c93ca93a6b4d850a8ad75a9edfcb38'
ORIGINAL_SCHEDULE = 'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate)))'
ISOLATED_SCHEDULE = 'TimelineView(.explicit([isolatedTimelineDate]))'
STATE_DECLARATION = '    @State private var isolatedTimelineDate: Date\n'
STATE_ASSIGNMENT = '        _isolatedTimelineDate = State(initialValue: Date())\n'
STATE_ANCHOR = '    @State private var particleSystem: VortexSystem\n'
INIT_ANCHOR = '        _particleSystem = State(initialValue: system)\n'
BODY_ANCHOR = '    public var body: some View {\n'

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def isolate_timeline(local: Path, original_swift_sha256: dict) -> dict:
    if len(original_swift_sha256) != 26 or original_swift_sha256.get(VIEW) != ORIGINAL_VIEW_SHA256:
        raise ValueError('Unexpected pinned Vortex Swift inventory')
    for name, expected in original_swift_sha256.items():
        if digest((local / name).read_bytes()) != expected:
            raise ValueError('Unclean upstream source before Timeline isolation: ' + name)
    target = local / VIEW
    original = target.read_bytes()
    schedule = ORIGINAL_SCHEDULE.encode()
    state = STATE_DECLARATION.encode()
    assignment = STATE_ASSIGNMENT.encode()
    adapted = original
    if adapted.count(schedule) != 1 or adapted.count(STATE_ANCHOR.encode()) != 1 or adapted.count(INIT_ANCHOR.encode()) != 1:
        raise ValueError('Unexpected Timeline schedule/property/init source')
    adapted = adapted.replace(schedule, ISOLATED_SCHEDULE.encode(), 1)
    adapted = adapted.replace(STATE_ANCHOR.encode(), STATE_ANCHOR.encode() + state, 1)
    adapted = adapted.replace(INIT_ANCHOR.encode(), INIT_ANCHOR.encode() + assignment, 1)
    required = [
        b'@State private var isolatedTimelineDate: Date',
        b'_isolatedTimelineDate = State(initialValue: Date())',
        b'TimelineView(.explicit([isolatedTimelineDate]))',
        b'Canvas { context, size in',
        b'particleSystem.update(date: timeline.date, drawSize: size)',
        b'draw(particleSystem, into: context, at: size)',
        b'} symbols: {', b'private func draw(',
        b'contextCopy.draw(symbol, at: .zero)', b'targetFrameRate: Int = 60',
    ]
    inserted = {required[0], required[1], required[2]}
    if not all(adapted.count(token) == original.count(token) + (1 if token in inserted else 0)
               for token in required):
        raise ValueError('Unexpected change to update/Canvas/symbols/draw/default60')
    restored = adapted.replace(ISOLATED_SCHEDULE.encode(), schedule, 1)
    restored = restored.replace(assignment, b'', 1)
    restored = restored.replace(state, b'', 1)
    if restored != original:
        raise ValueError('Exact Timeline reverse proof failed')
    target.write_bytes(adapted)
    compiled = {name: digest((local / name).read_bytes()) for name in original_swift_sha256}
    changed = [name for name in original_swift_sha256 if compiled[name] != original_swift_sha256[name]]
    if changed != [VIEW]:
        raise ValueError('Only VortexView may change for Timeline isolation')
    return {
        'scope': 'whole-test-interval',
        'schedule_kind': 'one explicit date, stable @State timestamp',
        'animation_schedule_replaced': True,
        'recurring_animation_ticks_removed_from_schedule': True,
        'initial_canvas_update_draw_opportunity_retained': True,
        'update_call_retained': True,
        'draw_retained': True,
        'suppressed_recurring_schedule_count': 1,
        'view_original_sha256': digest(original),
        'view_adapted_sha256': digest(adapted),
        'reverse_restores_upstream': True,
    }
