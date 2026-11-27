# Letterpress test9 — native display-link driver, no wake diagnostics

Version `0.1.0~test9`. This RootHide SpringBoard injection tweak and Preferences bundle derive from the complete frozen test8 non-diagnostic source tree, not a stack of isolate changes. The original SwiftUI/Vortex particle simulation, drawing, symbols, Reader, lyrics and default 60 target are retained. VortexView uses a lifecycle-owned CADisplayLink instead of TimelineView for recurring frames. This is a candidate, not a proven wake fix or a guarantee of device frame rate.

The wake diagnostic sampler, worker snapshots, command notifications, diagnostic settings controller and JSON export are absent from runtime sources and build inputs. Existing device preference/report files are not deleted, migrated or reset. No diagnostic upload, automatic installation or background monitoring is added.

Window/security/SBS/scene behavior, media handling, user defaults, particle parameters, identities and original license attribution remain unchanged. The user requested both a driver replacement and diagnostic removal, so this is not a strict single-factor experiment. Static checks and Apple compilation cannot establish on-device visual equivalence or eliminate wake delay by themselves.

Install manually over the same package and respring. Keep the same track and settings, verify real lyrics and moving particles, then lock for 5–10 seconds and wake twice. Report wake delay and particle motion; no repeated diagnostic JSON is requested. Keep isolate6 as the known non-repeating-driver comparison.
