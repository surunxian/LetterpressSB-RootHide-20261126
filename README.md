# Letterpress isolate6 — Timeline periodic-schedule isolation

Version `0.1.0~test8+isolate6`, derived from the complete frozen test8+diag2/default60 source tree, not from isolate5. The only renderer change replaces Vortex's repeating animation `TimelineSchedule` with a one-entry explicit schedule. A stable `@State` date prevents normal view-body reevaluation from manufacturing a fresh schedule date.

`TimelineView`, `Canvas`, the `particleSystem.update(date:drawSize:)` call, symbols closure, Reader path, original `draw` implementation/call, and `targetFrameRate: 60` remain. The one initial scheduled Canvas/update/draw opportunity is retained; recurring animation ticks are removed from the schedule. The ordinary lyrics and all window/security/SBS/scene/media/configuration paths are unchanged.

**Interpretation limits:** this isolates the repeating Timeline schedule, not the Timeline framework itself. The one-shot update may create few or no visible particles; burst callbacks remain. Other view invalidations, layout, or host lifecycle can still re-evaluate content. The test does not prove actual device cadence, a Timeline-only root cause, or a wake fix. Keep the same song/settings, verify real lyrics, then do two lock 5–10s/wake cycles. Report wake delay and lyrics; no repeated JSON requested. No installation, user-config reset, or diagnostic upload is automated.
