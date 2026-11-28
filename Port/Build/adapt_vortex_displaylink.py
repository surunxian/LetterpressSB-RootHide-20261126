#!/usr/bin/env python3
"""Single-file, reversible no-Canvas isolation with test9's CADisplayLink clock.

Call adapt_displaylink(local, original_swift_sha256) on an isolated copy only.
The clock publishes Date and a tiny SwiftUI marker consumes it; particles and
Canvas are temporarily absent from the body. No equivalent workload or frame
submission is claimed. No build, network, host lifecycle edits or diagnostics.
The exact original inventory is embedded, not trusted from the caller.
"""
from pathlib import Path
import hashlib

REVISION = '26e036c4f04efcc019c95d43bfeffeaefbef3c99'
VIEW = 'Sources/Vortex/Views/VortexView.swift'
ORIGINAL_VIEW_SHA256 = '8050f795edae1e23dcc742334d68d26fd4c93ca93a6b4d850a8ad75a9edfcb38'
PINNED_SWIFT_SHA256 = {
    'Sources/Vortex/Helpers/Angle+Codable.swift': 'c7e56c042a3e606aacaecfee5526aaa7adacfdf604f1a9fb46389ece6657c034',
    'Sources/Vortex/Helpers/Array-InterpolatedColor.swift': '14b21bc84aa966b3684a3bb2f3fd1f63dc904f69c97cf985c1d741fcf8ae5ec3',
    'Sources/Vortex/Helpers/Lerping.swift': 'b9ab21bdfaee08391a5420266abfa36be5784d0b4c7aae25a5a8da46eafa089b',
    'Sources/Vortex/Helpers/RandomSpread.swift': 'b7b94374ca060cfdbd9433b751cddf29850d4dea4cd5b841af22801fdd884c31',
    'Sources/Vortex/Presets/Confetti.swift': 'be865cb256ae30b5a0ffe100b3cbc5310c47b51d2c16f0d8fbd97fbeb2c02d12',
    'Sources/Vortex/Presets/Fire.swift': '6422ee0fa4e1f3ec23be9c54266e030ba77577b4914524589ff700f5c6d06714',
    'Sources/Vortex/Presets/Fireflies.swift': 'bf9fb96719660153b213175e3d2773bc7bfa03f9701cedb0e1195fffd116acc3',
    'Sources/Vortex/Presets/Fireworks.swift': '58bc5245b806055b73642583050c903209b4baed76d6fc318ab9c7918405a10a',
    'Sources/Vortex/Presets/Magic.swift': '0160204d0d0d2b199dd8ea2c5fbcdb0f62898f090f510f22f8f9a65f07cd0339',
    'Sources/Vortex/Presets/Rain.swift': 'b91c53c830a4185aa71898211c9cefd33c9eebbbf7742022728cfac5f45412e5',
    'Sources/Vortex/Presets/Smoke.swift': 'bb34f0114142c53e060b988c5c009681fc54f4b7a37d3e0c10408ff926a22d37',
    'Sources/Vortex/Presets/Snow.swift': '94fe493054be0f05b120f2d43abbbe14e3fad668c1619db0f8a6db50956c905c',
    'Sources/Vortex/Presets/Spark.swift': 'd1aa1462064ea98f20a4cfee2512ad007b9af157f4e2058a2f81316babf415a0',
    'Sources/Vortex/Presets/Splash.swift': '59cbe554def18a00ab928502c3b9f576233aa934c0a125aeaa8dda7dbd844e89',
    'Sources/Vortex/Resources/DefaultSymbols.swift': 'b0ef8db531ad7d719584bc5a73940d0acca67c39a8fc588f9af08361639630df',
    'Sources/Vortex/System/Color.swift': '70a472aa275a7e2f53e71fef2c9b9792ce599e1d49c172d7d29944233ea0d0b4',
    'Sources/Vortex/System/ColorMode.swift': '1cc1deadbc829b82b2c11adf52782fda324652236d6d191e15430a657a2846fc',
    'Sources/Vortex/System/Particle.swift': 'b8a783e2c032beb194962111f4609f9618899a2a081e6bc3a1ae8dd9affea227',
    'Sources/Vortex/System/Shape.swift': 'f1cd24c3b9f821dd31e2d845182010b47d6ed6dcc844ab4162fbe36eba92a8c1',
    'Sources/Vortex/System/SpawnOccasion.swift': '30185d955350d42b86e795e3abf08bf84ce77c66fab1ee7e966ed812b02e8546',
    'Sources/Vortex/System/VortexSystem-Behavior.swift': 'a1b85697b654d37760c97bae8ad0ea2c3df2a6859adebeffc0a19f1cc8493d96',
    'Sources/Vortex/System/VortexSystem.swift': '50d2b423cd6fd986975258e5f737e3046cea39f7641d8c1e603878d210c0b838',
    'Sources/Vortex/Views/VortexProxy.swift': '331d32bd107d4728b7754a00472b8f89167c84112680bf77ad2b10bd77ae264b',
    'Sources/Vortex/Views/VortexSystemPreferenceKey.swift': '2822c174d1b6af59f6a46f1579fb37880187b0e01ae17b87304c4feb3afbd057',
    VIEW: ORIGINAL_VIEW_SHA256,
    'Sources/Vortex/Views/VortexViewReader.swift': '6910bae0ba1d59d80ed8cad33cc201cf47e6cb8435b797b31271b47d1721f76f',
}

# Exact byte anchors: replace the entire Canvas branch, not layered noDraw/noUpdate edits.
CANVAS = b'''            Canvas { context, size in
                particleSystem.update(date: timeline.date, drawSize: size)
                draw(particleSystem, into: context, at: size)
            } symbols: {
                symbols
            }
'''
MARKER = b'''            GeometryReader { _ in
                let seconds = clockDate.timeIntervalSinceReferenceDate
                let fraction = seconds - seconds.rounded(.down)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                    .opacity(0.35 + 0.65 * fraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
'''
TEST9_HELPERS_SHA256 = '9abd68f0416eddf95508799729a3b15af1441efde32a7a31684db6927dcc72e3'

EDITS = (
    (b'import SwiftUI\n', b'import SwiftUI\nimport UIKit\nimport QuartzCore\n'),
    (b'TimelineView(.animation(minimumInterval: 1 / Double(targetFrameRate))) { timeline in',
     b'_VortexDisplayLinkView(targetFrameRate: targetFrameRate) { clockDate in'),
    (CANVAS, MARKER),
)

HELPERS = b'''
// The mounted wrapper owns one clock; only that clock owns its display link.
private struct _VortexDisplayLinkView<Content: View>: View {
    @StateObject private var clock = _VortexDisplayLinkClock()
    let targetFrameRate: Int
    let content: (Date) -> Content

    init(targetFrameRate: Int, @ViewBuilder content: @escaping (Date) -> Content) {
        self.targetFrameRate = targetFrameRate
        self.content = content
    }

    var body: some View {
        content(clock.date)
            .onAppear { clock.start(targetFrameRate: targetFrameRate) }
            .onDisappear { clock.stop() }
            .onChange(of: targetFrameRate) { newValue in
                clock.update(targetFrameRate: newValue)
            }
    }
}

private final class _VortexDisplayLinkClock: ObservableObject {
    @Published private(set) var date = Date()
    private var displayLink: CADisplayLink?

    func start(targetFrameRate: Int) {
        guard displayLink == nil else {
            update(targetFrameRate: targetFrameRate)
            return
        }
        let target = _VortexDisplayLinkTarget(clock: self)
        let link = CADisplayLink(target: target, selector: #selector(_VortexDisplayLinkTarget.step(_:)))
        link.preferredFramesPerSecond = targetFrameRate
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func update(targetFrameRate: Int) {
        displayLink?.preferredFramesPerSecond = targetFrameRate
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func tick() {
        date = Date()
    }

    deinit {
        displayLink?.invalidate()
    }
}

private final class _VortexDisplayLinkTarget: NSObject {
    private weak var clock: _VortexDisplayLinkClock?

    init(clock: _VortexDisplayLinkClock) {
        self.clock = clock
        super.init()
    }

    @objc func step(_ link: CADisplayLink) {
        clock?.tick()
    }
}
'''


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _once(data: bytes, old: bytes, new: bytes) -> bytes:
    if data.count(old) != 1:
        raise ValueError('Exact source anchor must occur once: ' + repr(old))
    return data.replace(old, new, 1)


def restore_displaylink(adapted: bytes) -> bytes:
    """Pure reverse proof; never writes a source tree and rejects foreign input."""
    if adapted.count(HELPERS) != 1 or not adapted.endswith(HELPERS):
        raise ValueError('Exact display-link helper suffix missing or duplicated')
    restored = adapted[:-len(HELPERS)]
    for old, new in reversed(EDITS):
        restored = _once(restored, new, old)
    if digest(restored) != ORIGINAL_VIEW_SHA256:
        raise ValueError('Reverse proof did not recover the pinned original')
    return restored


def _read_sources(local: Path) -> dict:
    """Read pinned sources and pre-existing packaging sources, without following links."""
    sources = local / 'Sources'
    if local.is_symlink() or not local.is_dir() or sources.is_symlink():
        raise ValueError('Expected a real isolated package directory')
    result = {}
    # Pinned paths are checked independently, so missing inventory cannot hide files.
    names = set(PINNED_SWIFT_SHA256)
    names.update(str(p.relative_to(local)) for p in sources.rglob('*.swift'))
    for name in sorted(names):
        p = local / name
        parts = Path(name).parts
        if any((local.joinpath(*parts[:i])).is_symlink() for i in range(1, len(parts) + 1)):
            raise ValueError('Symlink source/ancestor forbidden: ' + name)
        if not p.is_file():
            raise ValueError('Missing original Swift source: ' + name)
        result[name] = p.read_bytes()
    return result


def _structure(original: bytes, adapted: bytes) -> dict:
    # Entire original draw function, including its existing symbol-miss print,
    # must survive exactly; no new logging is introduced by the driver.
    draw_anchor = b'    /// Draws one particle system inside the canvas.\n'
    if original.count(draw_anchor) != 1:
        raise ValueError('Unexpected original draw boundary')
    main = adapted[:-len(HELPERS)]
    body_start = b'    public var body: some View {\n'
    body_end = b'    /// Creates a new VortexView from a pre-configured particle system'
    if any(data.count(anchor) != 1 for data in (original, main) for anchor in (body_start, body_end)):
        raise ValueError('Unexpected original/adapted body boundary')
    body = main[main.index(body_start):main.index(body_end)]
    kept_tokens = (
        b'@State private var particleSystem: VortexSystem',
        b'public var targetFrameRate: Int', b'targetFrameRate: Int = 60',
        b'_particleSystem = State(initialValue: system)',
        b'self.targetFrameRate = targetFrameRate', b'self.symbols = symbols()',
        b'.preference(key: VortexSystemPreferenceKey.self, value: particleSystem)',
    )
    checks = {
        'no_timeline_view_or_schedule': all(t not in adapted for t in
            (b'TimelineView', b'.animation', b'.explicit')),
        'whole_canvas_branch_replaced_once': original.count(CANVAS) == 1 and body.count(MARKER) == 1,
        'no_canvas_update_draw_or_symbols_in_body': all(t not in body for t in
            (b'Canvas', b'particleSystem.update(', b'draw(', b'symbols')),
        'marker_consumes_clock_date': all(body.count(t) == 1 for t in
            (b'{ clockDate in', b'let seconds = clockDate.timeIntervalSinceReferenceDate',
             b'let fraction = seconds - seconds.rounded(.down)', b'.opacity(0.35 + 0.65 * fraction)')),
        'marker_is_flexible_top_leading_white_4x4_noninteractive_accessibility_hidden': all(body.count(t) == 1 for t in
            (b'GeometryReader { _ in', b'Rectangle()', b'.fill(Color.white)',
             b'.frame(width: 4, height: 4)',
             b'.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)',
             b'.allowsHitTesting(false)', b'.accessibilityHidden(true)')),
        'symbols_storage_and_initializer_retained': all(main.count(t) == original.count(t) == 1 for t in
            (b'@ViewBuilder var symbols: Symbols', b'@ViewBuilder symbols: () -> Symbols = {', b'self.symbols = symbols()')),
        'no_text_or_added_marker_diagnostics': all(t not in MARKER for t in
            (b'Text(', b'print(', b'Logger', b'os_log', b'Timer', b'Task', b'DispatchQueue')),
        'test9_helpers_byte_identical': digest(HELPERS) == TEST9_HELPERS_SHA256,
        'draw_algorithm_byte_identical': main[main.index(draw_anchor):] == original[original.index(draw_anchor):],
        'parameters_default60_system_preference_retained': all(main.count(t) == original.count(t) == 1 for t in kept_tokens),
        'helpers_exact_private_suffix': adapted.endswith(HELPERS) and adapted.count(HELPERS) == 1,
        'one_stateobject_clock_per_wrapper': HELPERS.count(b'@StateObject private var clock =') == 1,
        'one_link_allocation_site': HELPERS.count(b'CADisplayLink(target:') == 1,
        'main_runloop_common_mode': HELPERS.count(b'link.add(to: .main, forMode: .common)') == 1,
        'direct_requested_fps_no_clamp': HELPERS.count(b'preferredFramesPerSecond = targetFrameRate') == 2,
        'idempotent_appear_start': b'guard displayLink == nil else {' in HELPERS,
        'disappear_invalidates_and_clears': b'displayLink?.invalidate()\n        displayLink = nil' in HELPERS,
        'weak_target_breaks_retain_cycle': b'private weak var clock: _VortexDisplayLinkClock?' in HELPERS,
        'deinit_defensive_invalidate': b'deinit {\n        displayLink?.invalidate()' in HELPERS,
        'fps_change_updates_existing_link': b'.onChange(of: targetFrameRate)' in HELPERS and b'displayLink?.preferredFramesPerSecond = targetFrameRate' in HELPERS,
        'date_delivered_synchronously': b'func tick() {\n        date = Date()' in HELPERS,
        'no_async_timer_notifications_or_added_logging': all(t not in HELPERS for t in
            (b'DispatchQueue', b'Task', b'Timer', b'NotificationCenter', b'print(', b'os_log', b'Logger', b'scenePhase', b'isCaptured', b'isIdleTimerDisabled')),
        'exact_reverse_proof': restore_displaylink(adapted) == original,
    }
    if not all(checks.values()):
        raise ValueError('Driver structure/preservation check failed: ' + repr(checks))
    return checks


def adapt_displaylink(local: Path, original_swift_sha256: dict) -> dict:
    """Modify ONLY VortexView.swift, once, after full 26-source validation.

    original_swift_sha256 must equal the embedded original Sources inventory.
    Packaging-only extra Swift sources are snapshotted and must be unchanged.
    The returned `compiled_swift_sha256` names *compile-input* bytes, not a
    claim that this adapter performed compilation or any on-device testing.
    """
    if not isinstance(original_swift_sha256, dict) or original_swift_sha256 != PINNED_SWIFT_SHA256:
        raise ValueError('Unexpected pinned Vortex Swift inventory: require exact 26 paths/hashes')
    local = Path(local)
    before = _read_sources(local)
    for name, expected in PINNED_SWIFT_SHA256.items():
        if digest(before[name]) != expected:
            raise ValueError('Unclean upstream source before display-link adaptation: ' + name)
    original = before[VIEW]
    if not original.endswith(b'}\n') or b'_VortexDisplayLink' in original:
        raise ValueError('Unexpected original view boundary or pre-existing driver')
    adapted = original
    for old, new in EDITS:
        adapted = _once(adapted, old, new)
    adapted += HELPERS
    checks = _structure(original, adapted)
    # No source writes occur before every hash, anchor and reverse proof passes.
    (local / VIEW).write_bytes(adapted)
    after = _read_sources(local)
    if set(before) != set(after):
        raise ValueError('Swift source inventory changed during adaptation')
    changed = [name for name in before if before[name] != after[name]]
    if changed != [VIEW] or after[VIEW] != adapted:
        raise ValueError('Unexpected post-write source bytes; inspect isolated copy')
    return {
        'upstream_revision': REVISION,
        'driver_kind': 'native CADisplayLink / private StateObject ObservableObject wrapper',
        'scope': 'only original Sources/Vortex/Views/VortexView.swift',
        'original_swift_file_count': 26,
        'unchanged_original_swift_file_count': 25,
        'changed_original_swift_files': changed,
        'original_swift_sha256': dict(PINNED_SWIFT_SHA256),
        'compiled_swift_sha256': {n: digest(after[n]) for n in PINNED_SWIFT_SHA256},
        'compiled_sha_meaning': 'compile-input source hashes only; no compiler was run',
        'preexisting_extra_swift_sha256': {n: digest(after[n]) for n in before if n not in PINNED_SWIFT_SHA256},
        'view_original_sha256': digest(original),
        'view_adapted_sha256': digest(adapted),
        'restored_view_sha256': digest(restore_displaylink(after[VIEW])),
        'reverse_restores_upstream': True,
        'structure_checks': checks,
        'simulation_changed': True,
        'simulation_algorithm_changed': False,
        'canvas_isolation': {
            'enabled': True,
            'no_canvas': True,
            'update_invocations_in_body': 0,
            'draw_invocations_in_body': 0,
            'particles_enabled': False,
            'symbols_rendered': False,
            'symbols_storage_and_initialization_retained': True,
            'draw_function_byte_identical': checks['draw_algorithm_byte_identical'],
            'marker_consumes_date': checks['marker_consumes_clock_date'],
            'marker': '4x4 white rectangle, top-leading; opacity = 0.35 + 0.65 * fractional reference seconds',
            'marker_noninteractive': True,
            'marker_accessibility_hidden': True,
            'clock_helpers_unchanged_from_test9': checks['test9_helpers_byte_identical'],
            'clock_helpers_sha256': digest(HELPERS),
            'clock_publishes_date_on_callback': True,
            'mounted_lifecycle_required': True,
            'equal_render_workload_claimed': False,
            'per_callback_frame_submission_claimed': False,
        },
        'host_lifecycle_changed': False,
        'new_diagnostics_or_logging': False,
        'swift_language_mode_requested': '5',
        'apple_xcode_requested': '16.2',
        'deployment_target_requested': 'iOS 16',
        'apple_compiler_run': False,
        'device_tested': False,
        'validation_level': 'offline exact bytes and static structure only',
    }
