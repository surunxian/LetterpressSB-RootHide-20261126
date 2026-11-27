#ifndef LPSB_WAKE_DIAGNOSTICS_H
#define LPSB_WAKE_DIAGNOSTICS_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LPWakeStage {
    LPWakeStageRefreshBegin = 1,
    LPWakeStageRefreshEnd = 2,
    LPWakeStageSceneChanged = 3,
    LPWakeStageWindowRegisterBegin = 4,
    LPWakeStageWindowRegisterEnd = 5,
    LPWakeStageWindowUnregister = 6,
    LPWakeStageRootCreateBegin = 7,
    LPWakeStageRootCreateEnd = 8,
    LPWakeStageBlankCallback = 9,
    LPWakeStageLockCallback = 10,
    LPWakeStageKeybagCallback = 11
} LPWakeStage;

/* SpringBoard only; call once from its main thread after startup. No hooks are
 * installed here. Mark/Window and the run-loop callback do only clock/atomic
 * numeric work: no Foundation, allocation, logging, symbol lookup or disk I/O.
 * Install itself captures the current pthread's known stack bounds and a Mach
 * send right, then asynchronously bootstraps all collectors off the main thread.
 * Window arguments are opaque numbers: flags are caller-defined, not policy.
 */
void LPSBWakeDiagnosticsInstall(void);
void LPSBWakeDiagnosticMark(uint32_t code, uint64_t a, uint64_t b);
void LPSBWakeDiagnosticWindow(uint64_t context, uint64_t scene, uint64_t flags);

/* Wire protocol (explicit CFPreferences application domain, never main prefs):
 * domain: com.82flex.letterpress.diagnostics
 * key request: NSDictionary { command: start|stop|clear,
 *                            requestID: UUID NSString, issuedAtUnix: NSNumber }
 * synchronize request BEFORE notify_post of the same domain + ".command".
 * key report: JSON NSString, NOT an NSDictionary. schema=1.
 * Busy/replay/stale command rejections use lastCommand in the existing report;
 * root requestID/status and any current recording are preserved.
 * No separate file is exported. A failed CFPreferences synchronization is
 * retried once with status=error and a numeric persistenceError if possible.
 *
 * events rows: [continuousClockNanosecondsSinceStart, numericCode, a, b].
 * 1..11 = LPWakeStage; 100=window(context,scene), 101=window flags;
 * 200=start, 201=main ack(queueDelayNs,0), 202=finish(reason,0);
 * 210=background blank receipt(state,notify error), 211=lock receipt;
 * 220=skip(reason,detail), 221=sample(index,busyNs).
 * Skip reasons: 1=idle, 2=busy<=250ms, 3=spacing, 4=per-busy cap,
 * 5=capture cap, 6=timer gap, 7=busy interval suppressed after a failed Mach
 * register/info query, 8=reserved, 9=observer not seen. After a timer gap the
 * collector requires a fresh continuous 250ms observation window. Known blank
 * does not veto sampling: the target scene stall can occur before unblank.
 * Sample busyNs is age since max(run-loop busy stamp, last timer gap/start);
 * runLoopBusyAgeNsIncludesSleep is raw age and may include sleep or descheduling.
 * timerContinuityNs and blankKnown/blankState preserve that context. None of
 * these fields alone proves a hang or measures physical wake latency. queueDelayNs
 * measures capture-start to main-ack, including background startup work; while
 * pending it is a numeric elapsed lower bound, not physical wake latency.
 * Sample errors: 0=none, 1=state, 2=info, 3=bounds unavailable,
 * 4=FP alignment/bounds, 5=nonincreasing FP, 6=1MiB span,
 * 7=VM read, 8=short VM read, 9=unsupported architecture,
 * 10=short state/info, 11=busy changed during query.
 * Samples are non-suspending, best-effort register/FP observations, NOT full
 * DWARF stacks or reliable atomic snapshots. Target memory may change between
 * reads. PC/LR/FP are SDK-accessor/PAC-stripped numeric addresses; stack words
 * retain the numeric saved LR as well. No pointer masking guesses are used.
 * Background notification times are process callback receipts, NOT physical
 * wake times. Main Blank/Lock/Keybag stages mean delivery to existing hooks.
 */
#ifdef __cplusplus
}
#endif
#endif
