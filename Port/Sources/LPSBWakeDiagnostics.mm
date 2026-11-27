#import "LPSBWakeDiagnostics.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
// iPhoneOS SDK mach/mach_vm.h is intentionally an unsupported stub. The MIG
// routine is exported by libSystem; use its documented 64-bit ABI declaration.
extern "C" kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
    mach_vm_address_t address, mach_vm_size_t size, mach_vm_address_t data,
    mach_vm_size_t *outsize);
#import <mach/arm/thread_status.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <notify.h>
#import <pthread.h>
#import <ptrauth.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <unistd.h>

namespace {
constexpr uint32_t kEvents = 2048, kSamples = 24, kFrames = 48;
constexpr uint32_t kImages = 192, kNonces = 128;
constexpr uint32_t kWorkerSnapshots = 4, kWorkerScan = 96, kWorkers = 24, kWorkerFrames = 24;
constexpr uint64_t kSpan = 1024 * 1024, kMaxJSON = 1024 * 1024;
constexpr uint64_t kWorkerBudgetNS = 20 * 1000000;
constexpr uint64_t kMS = 1000000, kSecond = 1000000000;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "64-bit atomics required");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "32-bit atomics required");
struct Event {
    std::atomic<uint32_t> writing{0};
    std::atomic<uint64_t> ticket{0}, epoch{0}, time{0}, code{0}, a{0}, b{0};
};
static Event gEvents[kEvents];
static std::atomic<uint64_t> gTicket{0}, gDropped{0}, gActive{0}, gDeadline{0};
static std::atomic<uint64_t> gBusy{0}, gAckEpoch{0}, gAckTime{0};
static std::atomic<uint64_t> gWindowSeq{0}, gContext{0}, gScene{0}, gFlags{0};
static std::atomic<uint64_t> gStage{0}, gStageTime{0};
static std::atomic<uint32_t> gInstalled{0}, gDepth{0}, gObserverSeen{0};
static thread_t gMainThread = MACH_PORT_NULL;
static uint64_t gStackLow, gStackHigh;
static dispatch_queue_t gQueue;
static dispatch_source_t gTimer;
static CFRunLoopObserverRef gObserver;
static mach_timebase_info_data_t gTimebase;
static int gCommandToken = -1, gBlankToken = -1, gLockToken = -1;
static uint32_t gCommandError, gBlankError, gLockError;
static uint64_t gEpochCounter, gEpoch, gStart, gLastTick, gLastSample, gObservationStart;
static uint64_t gBusySampled, gSuppressedBusy, gStartTicket, gDroppedStart;
static uint64_t gSkip[10], gQueueDelay, gBlankState, gLockState;
static uint32_t gSampleCount, gPerBusy;
static bool gRecording, gAckReported, gBlankKnown, gLockKnown;
static double gStartUnix, gEndUnix;
static NSString *gRequestID;
static NSMutableDictionary *gPublished;
static NSArray *gImageReport;
static uint32_t gImageTotal, gImageHeadersChecked;
static bool gOwnImageIncluded;
struct Nonce { char uuid[37]; double expires; };
static Nonce gNonces[kNonces];
struct Sample {
    uint64_t time, busy, runLoopBusy, observationStart, blankKnown, blankState;
    uint64_t pc, lr, fp, stage, stageTime;
    uint64_t context, scene, flags, windowCoherent;
    int32_t error, machError, runState, suspendCount, cpuUsage, threadFlags;
    uint32_t frameCount;
    bool frameLimitReached;
    uint64_t frames[kFrames][3]; // FP, saved LR raw word, PAC-stripped saved LR
};
static Sample gSamples[kSamples];
// Capture is fixed-storage C/Mach work only; no names/paths/pthread pointers persist.
struct Worker {
    uint64_t threadID, begin, end, pc, lr, fp;
    int32_t error, machError, identifierError, basicError, extendedError;
    int32_t runState, suspendCount, cpuUsage, threadFlags;
    uint32_t frameCount;
    bool identifierShort, basicShort, extendedShort, renderNameHint;
    bool frameLimitReached, budgetExceeded;
    uint64_t frames[kWorkerFrames][3];
};
struct WorkerSnapshot {
    uint64_t begin, end, busy, mainBusyAtBegin, mainBusyAtEnd;
    uint32_t mainSampleIndex, totalThreads, scanStart, scanned, eligible, candidateCount, captured;
    uint32_t excludedMain, excludedCollector, identifierFailures, basicFailures, extendedFailures;
    uint32_t portsReleased, portReleaseFailures;
    int32_t error, machError, collectorReleaseError, arrayReleaseError, firstPortReleaseError;
    bool scanTruncated, candidatesTruncated, budgetExceeded, mainBusyStampChangedDuringCapture;
    Worker workers[kWorkers];
};
static WorkerSnapshot gWorkerSnapshots[kWorkerSnapshots];
static uint32_t gWorkerSnapshotCount, gWorkerScanCursor;
static uint64_t gWorkerAttemptedBusy;

static inline uint64_t Clock() noexcept { return mach_continuous_time(); }
static uint64_t NS(uint64_t ticks) noexcept {
    return (uint64_t)(((__uint128_t)ticks * gTimebase.numer) / gTimebase.denom);
}
static void EventAt(uint64_t epoch, uint64_t now, uint32_t code,
                    uint64_t a, uint64_t b) noexcept {
    if (!epoch || (code != 202 && now >= gDeadline.load(std::memory_order_relaxed))) return;
    uint64_t t = gTicket.fetch_add(1, std::memory_order_relaxed);
    Event &e = gEvents[t % kEvents];
    uint32_t expected = 0;
    if (!e.writing.compare_exchange_strong(expected, 1, std::memory_order_acquire)) {
        gDropped.fetch_add(1, std::memory_order_relaxed); return;
    }
    e.ticket.store(0, std::memory_order_release);
    e.epoch.store(epoch, std::memory_order_relaxed);
    e.time.store(now, std::memory_order_relaxed);
    e.code.store(code, std::memory_order_relaxed);
    e.a.store(a, std::memory_order_relaxed); e.b.store(b, std::memory_order_relaxed);
    e.ticket.store(t + 1, std::memory_order_release);
    e.writing.store(0, std::memory_order_release);
}
static void EventNow(uint32_t code, uint64_t a, uint64_t b) noexcept {
    EventAt(gActive.load(std::memory_order_acquire), Clock(), code, a, b);
}
// Permanent observer; never allocates, logs, or emits a per-turn event.
static void RunLoop(CFRunLoopObserverRef, CFRunLoopActivity activity, void *) {
    const uint64_t now = Clock();
    gObserverSeen.store(1, std::memory_order_relaxed);
    if (activity == kCFRunLoopEntry) {
        gDepth.fetch_add(1, std::memory_order_relaxed);
        uint64_t idle = 0;
        gBusy.compare_exchange_strong(idle, now, std::memory_order_release);
    } else if (activity == kCFRunLoopAfterWaiting) {
        gBusy.store(now, std::memory_order_release);
    } else if (activity == kCFRunLoopBeforeWaiting) {
        gBusy.store(0, std::memory_order_release);
    } else if (activity == kCFRunLoopExit) {
        uint32_t depth = gDepth.load(std::memory_order_relaxed);
        if (depth) gDepth.store(depth - 1, std::memory_order_relaxed);
        gBusy.store(depth > 1 ? now : 0, std::memory_order_release);
    }
}
static bool Read(uint64_t address, void *destination, size_t size,
                 int32_t &error) noexcept {
    mach_vm_size_t copied = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), address, size,
                                             (mach_vm_address_t)destination, &copied);
    if (kr != KERN_SUCCESS) { error = (int32_t)kr; return false; }
    if (copied != size) { error = KERN_INVALID_ADDRESS; return false; }
    return true;
}
static uint64_t StripCode(uint64_t p) noexcept {
    return (uint64_t)ptrauth_strip((void *)(uintptr_t)p, ptrauth_key_return_address);
}
static uint64_t StripFP(uint64_t p) noexcept {
    return (uint64_t)ptrauth_strip((void *)(uintptr_t)p, ptrauth_key_process_dependent_data);
}
static void Capture(uint64_t now, uint64_t busy, uint64_t observedSince) noexcept {
    Sample &s = gSamples[gSampleCount++];
    std::memset(&s, 0, sizeof(s));
    s.time = now; s.busy = observedSince; s.runLoopBusy = busy;
    s.observationStart = gObservationStart;
    s.blankKnown = gBlankKnown; s.blankState = gBlankState;
    s.stage = gStage.load(std::memory_order_relaxed);
    s.stageTime = gStageTime.load(std::memory_order_relaxed);
    uint64_t seq = gWindowSeq.load(std::memory_order_acquire);
    s.context = gContext.load(std::memory_order_relaxed);
    s.scene = gScene.load(std::memory_order_relaxed);
    s.flags = gFlags.load(std::memory_order_relaxed);
    s.windowCoherent = !(seq & 1) && seq == gWindowSeq.load(std::memory_order_acquire);
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state = {};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(gMainThread, ARM_THREAD_STATE64,
                                         (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) { s.error = 1; s.machError = kr; return; }
    if (count != ARM_THREAD_STATE64_COUNT) { s.error = 10; return; }
    // SDK handles opaque arm64e register representation; no guessed masks.
    s.pc = (uint64_t)ptrauth_strip((void *)(uintptr_t)arm_thread_state64_get_pc(state),
                                  ptrauth_key_function_pointer);
    s.lr = StripCode((uint64_t)arm_thread_state64_get_lr(state));
    s.fp = StripFP((uint64_t)arm_thread_state64_get_fp(state));
    thread_basic_info_data_t info = {};
    count = THREAD_BASIC_INFO_COUNT;
    kr = thread_info(gMainThread, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
    if (kr != KERN_SUCCESS) { s.error = 2; s.machError = kr; return; }
    if (count != THREAD_BASIC_INFO_COUNT) { s.error = 10; return; }
    s.runState = info.run_state; s.suspendCount = info.suspend_count;
    s.cpuUsage = info.cpu_usage; s.threadFlags = info.flags;
    if (gBusy.load(std::memory_order_acquire) != busy) { s.error = 11; return; }
    if (gStackHigh <= gStackLow || gStackHigh - gStackLow < 16) { s.error = 3; return; }
    uint64_t fp = s.fp, first = fp;
    for (uint32_t i = 0; i < kFrames; ++i) {
        if (!fp) return;
        if ((fp & 15) || fp < gStackLow || fp > gStackHigh - 16) { s.error = 4; return; }
        if (fp < first || fp - first > kSpan - 16) { s.error = 6; return; }
        uint64_t pair[2] = {}; mach_vm_size_t copied = 0;
        kr = mach_vm_read_overwrite(mach_task_self(), fp, sizeof(pair),
                                    (mach_vm_address_t)pair, &copied);
        if (kr != KERN_SUCCESS) { s.error = 7; s.machError = kr; return; }
        if (copied != sizeof(pair)) { s.error = 8; return; }
        s.frames[s.frameCount][0] = fp;
        s.frames[s.frameCount][1] = pair[1];
        s.frames[s.frameCount++][2] = StripCode(pair[1]);
        uint64_t next = StripFP(pair[0]);
        if (!next) return;
        if (next <= fp) { s.error = 5; return; }
        fp = next;
    }
    s.frameLimitReached = true;
#else
    s.error = 9;
#endif
}

// The 20ms budget is cooperative, not a bound on Mach syscall/cleanup latency.
static bool WorkerStop(WorkerSnapshot &s) noexcept {
    if (gBusy.load(std::memory_order_acquire) != s.busy) {
        s.mainBusyStampChangedDuringCapture = true;
        if (!s.error) s.error = 11;
    }
    if (NS(Clock() - s.begin) >= kWorkerBudgetNS) {
        s.budgetExceeded = true;
        if (!s.error) s.error = 20;
    }
    return s.mainBusyStampChangedDuringCapture || s.budgetExceeded;
}
static bool RenderNameHint(const char *name, size_t size) noexcept {
    // Only a bounded in-memory ranking hint, never identity or proof of ownership.
    const char *hints[] = {"render", "quartz", "com.apple.ca.", "metal", "agx"};
    for (const char *hint : hints) {
        size_t n = std::strlen(hint);
        for (size_t i = 0; i + n <= size && name[i]; ++i) {
            size_t j = 0;
            for (; j < n; ++j) {
                unsigned char c = (unsigned char)name[i + j];
                if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
                if (c != (unsigned char)hint[j]) break;
            }
            if (j == n) return true;
        }
    }
    return false;
}
static void CaptureWorker(thread_t thread, Worker &w, WorkerSnapshot &snapshot) noexcept {
#if defined(__arm64__) || defined(__aarch64__)
    if (WorkerStop(snapshot)) { w.error = snapshot.budgetExceeded ? 20 : 11; return; }
    arm_thread_state64_t state = {};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (kr != KERN_SUCCESS) { w.error = 1; w.machError = kr; return; }
    if (count != ARM_THREAD_STATE64_COUNT) { w.error = 10; return; }
    w.pc = (uint64_t)ptrauth_strip((void *)(uintptr_t)arm_thread_state64_get_pc(state),
                                   ptrauth_key_function_pointer);
    w.lr = StripCode((uint64_t)arm_thread_state64_get_lr(state));
    w.fp = StripFP((uint64_t)arm_thread_state64_get_fp(state));
    uint64_t fp = w.fp, first = fp;
    for (uint32_t i = 0; i < kWorkerFrames; ++i) {
        if (WorkerStop(snapshot)) { w.error = snapshot.budgetExceeded ? 20 : 11; return; }
        if (!fp) return;
        // No remote pthread dereference or guessed stack extent. VM validates each pair.
        if ((fp & 15) || fp > UINT64_MAX - 16) { w.error = 4; return; }
        if (fp < first || fp - first > kSpan - 16) { w.error = 6; return; }
        uint64_t pair[2] = {}; mach_vm_size_t copied = 0;
        kr = mach_vm_read_overwrite(mach_task_self(), fp, sizeof(pair),
                                    (mach_vm_address_t)pair, &copied);
        if (kr != KERN_SUCCESS) { w.error = 7; w.machError = kr; return; }
        if (copied != sizeof(pair)) { w.error = 8; return; }
        w.frames[w.frameCount][0] = fp;
        w.frames[w.frameCount][1] = pair[1];
        w.frames[w.frameCount++][2] = StripCode(pair[1]);
        uint64_t next = StripFP(pair[0]);
        if (!next) return;
        if (next <= fp) { w.error = 5; return; }
        fp = next;
    }
    w.frameLimitReached = true;
#else
    (void)thread; (void)snapshot; w.error = 9;
#endif
}
static void CaptureWorkers(uint32_t mainIndex) noexcept {
    WorkerSnapshot &s = gWorkerSnapshots[gWorkerSnapshotCount++];
    std::memset(&s, 0, sizeof(s));
    s.begin = Clock(); s.busy = gSamples[mainIndex].runLoopBusy; s.mainSampleIndex = mainIndex;
    s.mainBusyAtBegin = gBusy.load(std::memory_order_acquire);
    EventAt(gEpoch, s.begin, 230, gWorkerSnapshotCount - 1, mainIndex);
    // Defensive guard; Tick normally runs only on the serial diagnostic queue.
    if (pthread_main_np()) { s.error = 12; s.end = Clock(); return; }
    thread_t collector = mach_thread_self(); // owns a temporary send right, released below
    thread_act_array_t ports = nullptr; mach_msg_type_number_t total = 0;
    struct Candidate { thread_t port; Worker worker; } candidates[kWorkers] = {};
    auto Better = [](const Worker &a, const Worker &b) {
        if (a.renderNameHint != b.renderNameHint) return a.renderNameHint;
        bool ar = a.runState == TH_STATE_RUNNING, br = b.runState == TH_STATE_RUNNING;
        if (ar != br) return ar;
        if (a.cpuUsage != b.cpuUsage) return a.cpuUsage > b.cpuUsage;
        return a.threadID < b.threadID;
    };
    kern_return_t kr = KERN_SUCCESS;
    if (!MACH_PORT_VALID(collector)) s.error = 13;
    else if (!WorkerStop(s)) {
        kr = task_threads(mach_task_self(), &ports, &total);
        s.totalThreads = total;
        if (kr != KERN_SUCCESS) { s.error = 14; s.machError = kr; }
        else if (total && !ports) s.error = 15;
        else {
            s.scanStart = total ? gWorkerScanCursor % total : 0;
            const uint32_t limit = total < kWorkerScan ? total : kWorkerScan;
            for (uint32_t n = 0; n < limit; ++n) {
                if (WorkerStop(s)) break;
                uint32_t index = (uint32_t)(((uint64_t)s.scanStart + n) % total);
                ++s.scanned;
                thread_t port = ports[index];
                if (port == gMainThread) { ++s.excludedMain; continue; }
                if (port == collector) { ++s.excludedCollector; continue; }
                Worker w = {}; w.begin = Clock();
                thread_identifier_info_data_t identity = {};
                mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
                w.identifierError = thread_info(port, THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &count);
                w.identifierShort = w.identifierError == KERN_SUCCESS && count != THREAD_IDENTIFIER_INFO_COUNT;
                if (w.identifierError || w.identifierShort) ++s.identifierFailures;
                else w.threadID = identity.thread_id;
                if (!WorkerStop(s)) {
                    thread_basic_info_data_t info = {}; count = THREAD_BASIC_INFO_COUNT;
                    w.basicError = thread_info(port, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
                    w.basicShort = w.basicError == KERN_SUCCESS && count != THREAD_BASIC_INFO_COUNT;
                    if (w.basicError || w.basicShort) ++s.basicFailures;
                    else {
                        w.runState = info.run_state; w.suspendCount = info.suspend_count;
                        w.cpuUsage = info.cpu_usage; w.threadFlags = info.flags;
                    }
                } else w.basicError = KERN_ABORTED;
                if (!WorkerStop(s)) {
                    thread_extended_info_data_t info = {}; count = THREAD_EXTENDED_INFO_COUNT;
                    w.extendedError = thread_info(port, THREAD_EXTENDED_INFO, (thread_info_t)&info, &count);
                    w.extendedShort = w.extendedError == KERN_SUCCESS && count != THREAD_EXTENDED_INFO_COUNT;
                    if (w.extendedError || w.extendedShort) ++s.extendedFailures;
                    else w.renderNameHint = RenderNameHint(info.pth_name, sizeof(info.pth_name));
                    // info (including pth_name) is never copied into persistent storage.
                    std::memset(&info, 0, sizeof(info));
                } else w.extendedError = KERN_ABORTED;
                w.end = Clock(); ++s.eligible;
                uint32_t pos = 0;
                while (pos < s.candidateCount && !Better(w, candidates[pos].worker)) ++pos;
                if (pos < kWorkers) {
                    uint32_t last = s.candidateCount < kWorkers ? s.candidateCount++ : kWorkers - 1;
                    for (uint32_t j = last; j > pos; --j) candidates[j] = candidates[j - 1];
                    candidates[pos] = {port, w};
                }
            }
            // Advance even when a syscall consumed the budget before the first scan.
            gWorkerScanCursor = total ? (uint32_t)(((uint64_t)s.scanStart + (s.scanned ? s.scanned : 1)) % total) : 0;
            s.scanTruncated = s.scanned < total;
            s.candidatesTruncated = s.eligible > s.candidateCount;
            for (uint32_t i = 0; i < s.candidateCount; ++i) {
                Worker &w = s.workers[i]; w = candidates[i].worker;
                if (!WorkerStop(s)) { ++s.captured; CaptureWorker(candidates[i].port, w, s); }
                else w.error = s.budgetExceeded ? 20 : 11;
                w.end = Clock(); w.budgetExceeded = s.budgetExceeded;
            }
        }
    }
    // Cleanup is unconditional after task_threads, including partial/error returns.
    // It is intentionally NOT stopped by the soft budget: every acquired right must go.
    if (ports) {
        for (uint32_t i = 0; i < total; ++i) {
            kern_return_t e = mach_port_deallocate(mach_task_self(), ports[i]);
            if (e == KERN_SUCCESS) ++s.portsReleased;
            else { ++s.portReleaseFailures; if (!s.firstPortReleaseError) s.firstPortReleaseError = e; }
        }
        s.arrayReleaseError = vm_deallocate(mach_task_self(), (vm_address_t)ports,
                                            (vm_size_t)total * sizeof(thread_t));
    }
    if (MACH_PORT_VALID(collector)) s.collectorReleaseError = mach_port_deallocate(mach_task_self(), collector);
    (void)WorkerStop(s);
    s.mainBusyAtEnd = gBusy.load(std::memory_order_acquire); s.end = Clock();
    EventAt(gEpoch, s.end, 231, gWorkerSnapshotCount - 1, NS(s.end - s.begin));
}
static void MaybeCaptureWorkers() noexcept {
    if (gSampleCount < 2 || gWorkerSnapshotCount >= kWorkerSnapshots) return;
    const Sample &a = gSamples[gSampleCount - 2], &b = gSamples[gSampleCount - 1];
    if (b.runLoopBusy == gWorkerAttemptedBusy || a.runLoopBusy != b.runLoopBusy ||
        a.observationStart != b.observationStart || a.error || b.error ||
        a.runState != TH_STATE_WAITING || b.runState != TH_STATE_WAITING ||
        a.pc != b.pc || a.lr != b.lr || NS(b.time - b.busy) < 500 * kMS) return;
    gWorkerAttemptedBusy = b.runLoopBusy; // a failed attempt still consumes this busy interval
    CaptureWorkers(gSampleCount - 1);
}

// All dyld enumeration and Foundation work runs on the diagnostic serial queue.
// Image memory (including its name) is copied via Mach, never dereferenced.
static NSArray *CollectImages() {
    NSMutableArray *out = [NSMutableArray array];
    gImageTotal = _dyld_image_count();
    gImageHeadersChecked = gImageTotal < 4096 ? gImageTotal : 4096;
    gOwnImageIncluded = false;
    uint64_t headers[4096] = {};
    for (uint32_t i = 0; i < gImageHeadersChecked; ++i)
        headers[i] = (uint64_t)(uintptr_t)_dyld_get_image_header(i);
    uint32_t selected[kImages] = {}, count = 0;
    auto AddIndex = [&](uint32_t index) {
        if (count >= kImages) return;
        for (uint32_t i = 0; i < count; ++i) if (selected[i] == index) return;
        selected[count++] = index;
    };
    auto AddCode = [&](uint64_t code) -> uint64_t {
        if (!code) return 0;
        Dl_info image = {};
        if (!dladdr((const void *)(uintptr_t)code, &image) || !image.dli_fbase) return 0;
        uint64_t base = (uint64_t)(uintptr_t)image.dli_fbase;
        for (uint32_t i = 0; i < gImageHeadersChecked; ++i)
            if (headers[i] == base) { AddIndex(i); break; }
        return base;
    };
    // Performed only AFTER capture stops. Preserve our dSYM identity first,
    // then the images actually observed in code registers / saved return PCs.
    uint64_t ownBase = AddCode((uint64_t)ptrauth_strip(
        (void *)&LPSBWakeDiagnosticsInstall, ptrauth_key_function_pointer));
    for (uint32_t i = 0; i < gSampleCount && count < kImages; ++i) {
        AddCode(gSamples[i].pc); AddCode(gSamples[i].lr);
        for (uint32_t j = 0; j < gSamples[i].frameCount && count < kImages; ++j)
            AddCode(gSamples[i].frames[j][2]);
    }
    for (uint32_t i = 0; i < gWorkerSnapshotCount && count < kImages; ++i)
        for (uint32_t j = 0; j < gWorkerSnapshots[i].candidateCount && count < kImages; ++j) {
            const Worker &w = gWorkerSnapshots[i].workers[j];
            AddCode(w.pc); AddCode(w.lr);
            for (uint32_t f = 0; f < w.frameCount && count < kImages; ++f) AddCode(w.frames[f][2]);
        }
    for (uint32_t i = 0; i < gImageHeadersChecked && count < kImages; ++i) AddIndex(i);
    for (uint32_t slot = 0; slot < count; ++slot) {
        uint32_t i = selected[slot];
        const struct mach_header *address = (const struct mach_header *)(uintptr_t)headers[i];
        if (!address) continue;
        struct mach_header_64 header = {}; int32_t error = 0;
        uint64_t base = (uint64_t)(uintptr_t)address;
        if (!Read(base, &header, sizeof(header), error) || header.magic != MH_MAGIC_64) continue;
        char basename[97] = {}; char uuid[37] = {};
        const char *name = _dyld_get_image_name(i);
        // At most one page-contained name copy; never publish a partial path.
        char path[1024] = {};
        uint32_t used = 0;
        if (name) {
            uint64_t source = (uint64_t)(uintptr_t)name;
            uint64_t page = (uint64_t)getpagesize();
            size_t bytes = (size_t)(page - source % page);
            if (bytes > sizeof(path)) bytes = sizeof(path);
            if (Read(source, path, bytes, error)) {
                const char *nul = (const char *)std::memchr(path, 0, bytes);
                if (nul) {
                    const char *last = path;
                    for (const char *p = path; p < nul; ++p) if (*p == '/') last = p + 1;
                    size_t length = (size_t)(nul - last);
                    used = (uint32_t)(length < sizeof(basename) ? length : sizeof(basename) - 1);
                    std::memcpy(basename, last, used);
                }
            }
        }
        basename[used] = 0;
        uint64_t offset = sizeof(header);
        uint64_t limit = sizeof(header) + (uint64_t)header.sizeofcmds;
        const int64_t slide = (int64_t)_dyld_get_image_vmaddr_slide(i);
        NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:4];
        bool rangeTruncated = false; uint32_t executableSegments = 0;
        int32_t rangeError = 0, rangeMachError = 0;
        if (header.sizeofcmds > 65536 || header.ncmds > 1024 || base > UINT64_MAX - limit) rangeError = 1;
        else {
            for (uint32_t j = 0; j < header.ncmds; ++j) {
                if (offset > limit || limit - offset < sizeof(load_command)) { rangeError = 2; break; }
                struct load_command command = {};
                if (!Read(base + offset, &command, sizeof(command), rangeMachError)) { rangeError = 3; break; }
                if (command.cmdsize < sizeof(command) || command.cmdsize > limit - offset || (command.cmdsize & 7)) {
                    rangeError = 2; break;
                }
                if (command.cmd == LC_UUID) {
                    if (command.cmdsize < sizeof(uuid_command)) { rangeError = 2; break; }
                    struct uuid_command u = {};
                    if (!Read(base + offset, &u, sizeof(u), rangeMachError)) { rangeError = 3; break; }
                    static const char hex[] = "0123456789abcdef";
                    unsigned pos = 0;
                    for (unsigned k = 0; k < 16; ++k) {
                        if (k == 4 || k == 6 || k == 8 || k == 10) uuid[pos++] = '-';
                        uuid[pos++] = hex[u.uuid[k] >> 4]; uuid[pos++] = hex[u.uuid[k] & 15];
                    }
                    // Do not break: executable segments can follow LC_UUID.
                } else if (command.cmd == LC_SEGMENT_64) {
                    if (command.cmdsize < sizeof(segment_command_64)) { rangeError = 2; break; }
                    struct segment_command_64 segment = {};
                    if (!Read(base + offset, &segment, sizeof(segment), rangeMachError)) { rangeError = 3; break; }
                    uint64_t needed = sizeof(segment) + (uint64_t)segment.nsects * sizeof(section_64);
                    if (needed > command.cmdsize) { rangeError = 2; break; }
                    if ((segment.initprot & VM_PROT_EXECUTE) && segment.vmsize) {
                        ++executableSegments;
                        // True signed dyld slide: no unsigned wrap or guessed nearest base.
                        __int128 start = (__int128)segment.vmaddr + (__int128)slide;
                        __int128 end = start + (__int128)segment.vmsize;
                        if (segment.vmaddr > UINT64_MAX - segment.vmsize || start < 0 ||
                            start > UINT64_MAX || end > UINT64_MAX || end <= start) {
                            rangeError = 4;
                        } else if (ranges.count >= 4) rangeTruncated = true;
                        else [ranges addObject:@{ @"start":@((uint64_t)start), @"endExclusive":@((uint64_t)end),
                                                  @"initprot":@(segment.initprot) }];
                    }
                }
                offset += command.cmdsize;
            }
            if (!rangeError && offset != limit) rangeError = 2;
        }
        if (base == ownBase && uuid[0]) gOwnImageIncluded = true;
        NSString *n = [[NSString alloc] initWithBytes:basename length:used encoding:NSUTF8StringEncoding];
        NSString *u = [NSString stringWithUTF8String:uuid];
        [out addObject:@{@"basename":n ?: @"", @"uuid":u ?: @"", @"loadAddress":@(base),
                         @"slide":@(slide), @"executableRanges":ranges,
                         @"executableSegmentCount":@(executableSegments), @"rangeTruncated":@(rangeTruncated),
                         @"rangeError":@(rangeError), @"rangeMachError":@(rangeMachError),
                         @"executableRangesComplete":@(!rangeError && !rangeTruncated)}];
    }
    return out;
}
static NSMutableArray *EventsJSON() {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:kEvents];
    uint64_t end = gTicket.load(std::memory_order_acquire);
    uint64_t begin = end > kEvents ? end - kEvents : 0;
    if (begin < gStartTicket) begin = gStartTicket;
    for (uint64_t t = begin; t < end; ++t) {
        Event &e = gEvents[t % kEvents];
        if (e.writing.load(std::memory_order_acquire) || e.ticket.load(std::memory_order_acquire) != t + 1) continue;
        uint64_t epoch = e.epoch.load(std::memory_order_relaxed);
        uint64_t time = e.time.load(std::memory_order_relaxed);
        uint64_t code = e.code.load(std::memory_order_relaxed);
        uint64_t a = e.a.load(std::memory_order_relaxed), b = e.b.load(std::memory_order_relaxed);
        if (e.ticket.load(std::memory_order_acquire) != t + 1 || e.writing.load(std::memory_order_acquire)) continue;
        if (epoch == gEpoch && time >= gStart) [out addObject:@[@(NS(time - gStart)), @(code), @(a), @(b)]];
    }
    return out;
}
static NSArray *SamplesJSON() {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:gSampleCount];
    for (uint32_t i = 0; i < gSampleCount; ++i) {
        const Sample &s = gSamples[i];
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:s.frameCount];
        for (uint32_t j = 0; j < s.frameCount; ++j)
            [frames addObject:@[@(s.frames[j][0]), @(s.frames[j][1]), @(s.frames[j][2])]];
        [out addObject:@{@"tNs":@(NS(s.time - gStart)), @"busyNs":@(NS(s.time - s.busy)),
            @"runLoopBusyAgeNsIncludesSleep":@(NS(s.time - s.runLoopBusy)),
            @"timerContinuityNs":@(NS(s.time - s.observationStart)),
            @"blankKnown":@(s.blankKnown), @"blankState":@(s.blankState),
            @"pc":@(s.pc), @"lr":@(s.lr), @"fp":@(s.fp), @"error":@(s.error),
            @"machError":@(s.machError), @"runState":@(s.runState), @"suspendCount":@(s.suspendCount),
            @"cpuUsage":@(s.cpuUsage), @"threadFlags":@(s.threadFlags), @"frames":frames,
            @"frameLimitReached":@(s.frameLimitReached), @"atomicSnapshot":@NO,
            @"stage":@(s.stage), @"stageTimeNs":@(s.stageTime >= gStart ? NS(s.stageTime - gStart) : 0),
            @"window":@[@(s.context), @(s.scene), @(s.flags)], @"windowCoherent":@(s.windowCoherent)}];
    }
    return out;
}
static NSArray *WorkerSnapshotsJSON() {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:gWorkerSnapshotCount];
    for (uint32_t i = 0; i < gWorkerSnapshotCount; ++i) {
        const WorkerSnapshot &s = gWorkerSnapshots[i];
        NSMutableArray *workers = [NSMutableArray arrayWithCapacity:s.candidateCount];
        for (uint32_t j = 0; j < s.candidateCount; ++j) {
            const Worker &w = s.workers[j];
            NSMutableArray *frames = [NSMutableArray arrayWithCapacity:w.frameCount];
            for (uint32_t f = 0; f < w.frameCount; ++f)
                [frames addObject:@[@(w.frames[f][0]), @(w.frames[f][1]), @(w.frames[f][2])]];
            [workers addObject:@{@"thread_id":@(w.threadID),
                @"threadIDKnown":@(!w.identifierError && !w.identifierShort && w.threadID != 0),
                @"beginTNs":@(NS(w.begin - gStart)), @"endTNs":@(NS(w.end - gStart)),
                @"pc":@(w.pc), @"lr":@(w.lr), @"fp":@(w.fp), @"frames":frames,
                @"error":@(w.error), @"machError":@(w.machError),
                @"identifierError":@(w.identifierError), @"identifierShort":@(w.identifierShort),
                @"basicError":@(w.basicError), @"basicShort":@(w.basicShort),
                @"extendedError":@(w.extendedError), @"extendedShort":@(w.extendedShort),
                @"renderNameHint":@(w.renderNameHint), @"runState":@(w.runState),
                @"suspendCount":@(w.suspendCount), @"cpuUsage":@(w.cpuUsage), @"threadFlags":@(w.threadFlags),
                @"stackBoundsKnown":@NO, @"atomicSnapshot":@NO,
                @"frameLimitReached":@(w.frameLimitReached), @"budgetExceeded":@(w.budgetExceeded)}];
        }
        [out addObject:@{@"mainSampleIndex":@(s.mainSampleIndex),
            @"mainSampleTNs":@(NS(gSamples[s.mainSampleIndex].time - gStart)),
            @"beginTNs":@(NS(s.begin - gStart)), @"endTNs":@(NS(s.end - gStart)),
            @"elapsedNs":@(NS(s.end - s.begin)), @"softBudgetNs":@(kWorkerBudgetNS),
            @"budgetExceeded":@(s.budgetExceeded), @"atomicWithMain":@NO,
            @"mainWaitContinuityVerified":@NO,
            @"workerTiming":@"begin precedes metadata query; registers/FP captured later after ranking; end includes both phases; not atomic",
            @"mainBusyStampChangedDuringCapture":@(s.mainBusyStampChangedDuringCapture),
            @"mainBusyStampAtBegin":@(s.mainBusyAtBegin), @"mainBusyStampAtEnd":@(s.mainBusyAtEnd),
            @"processThreadCount":@(s.totalThreads), @"scanStartIndex":@(s.scanStart), @"scannedThreads":@(s.scanned),
            @"scanTruncated":@(s.scanTruncated), @"eligibleThreads":@(s.eligible),
            @"candidateCount":@(s.candidateCount), @"registerCaptureAttempts":@(s.captured),
            @"candidatesTruncated":@(s.candidatesTruncated), @"workers":workers,
            @"excludedMain":@(s.excludedMain), @"excludedCollector":@(s.excludedCollector),
            @"identifierFailures":@(s.identifierFailures), @"basicFailures":@(s.basicFailures),
            @"extendedFailures":@(s.extendedFailures), @"error":@(s.error), @"machError":@(s.machError),
            @"portsReleased":@(s.portsReleased), @"portReleaseFailures":@(s.portReleaseFailures),
            @"firstPortReleaseError":@(s.firstPortReleaseError),
            @"arrayReleaseError":@(s.arrayReleaseError), @"collectorReleaseError":@(s.collectorReleaseError)}];
    }
    return out;
}
static NSMutableDictionary *Report(NSString *status, bool full) {
    uint64_t now = Clock();
    NSMutableArray *skips = [NSMutableArray arrayWithCapacity:10];
    for (unsigned i = 0; i < 10; ++i) [skips addObject:@(gSkip[i])];
#if defined(__arm64e__)
    NSString *arch = @"arm64e";
#elif defined(__arm64__) || defined(__aarch64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"unsupported";
#endif
    uint64_t end = gTicket.load(std::memory_order_relaxed);
    uint64_t requested = end >= gStartTicket ? end - gStartTicket : 0;
    return [@{@"schema":@2, @"build":@"0.1.0~test8+isolate1", @"requestID":gRequestID ?: @"",
        @"status":status, @"startedAtUnix":@(gStartUnix), @"endedAtUnix":@(gEndUnix),
        @"duration":@(gStart ? NS(now - gStart) / (double)kSecond : 0),
        @"events":full ? EventsJSON() : @[], @"samples":full ? SamplesJSON() : @[],
        @"workerSnapshots":full ? WorkerSnapshotsJSON() : @[],
        @"images":gImageReport ?: @[], @"pid":@(getpid()), @"arch":arch,
        @"clock":@{@"name":@"mach_continuous_time", @"numer":@(gTimebase.numer), @"denom":@(gTimebase.denom)},
        @"queueDelayNs":@(gAckReported ? gQueueDelay : (gStart ? NS(now - gStart) : 0)),
        @"queueDelayIsLowerBound":@(!gAckReported),
        @"mainAckPending":@(!gAckReported),
        @"pendingElapsedNs":@(gStart && !gAckReported ? NS(now - gStart) : 0),
        @"skipCounts":skips,
        @"limits":@{@"seconds":@90, @"timerMs":@50, @"busyThresholdMs":@250, @"sampleSpacingMs":@250,
            @"maxTimerGapMs":@300, @"eventCapacity":@(kEvents), @"sampleCapacity":@(kSamples),
            @"perBusySamples":@6, @"maxFPFrames":@(kFrames), @"maxFPSpanBytes":@(kSpan),
            @"maxWorkerSnapshots":@(kWorkerSnapshots), @"workerSnapshotsAttempted":@(gWorkerSnapshotCount),
            @"workerSnapshotQuotaRemaining":@(kWorkerSnapshots - gWorkerSnapshotCount),
            @"workerTriggerBusyMs":@500, @"workerTriggerConsecutiveWaitingMainSamples":@2,
            @"workerAttemptsPerBusy":@1, @"maxWorkerThreadsScanned":@(kWorkerScan),
            @"maxWorkerCandidates":@(kWorkers), @"maxWorkerFPFrames":@(kWorkerFrames),
            @"maxWorkerFPBytesRead":@(kWorkers * kWorkerFrames * 16),
            @"workerSoftBudgetNs":@(kWorkerBudgetNS), @"workerBudgetIsHardRealtimeBound":@NO,
            @"maxExecutableRangesPerImage":@4,
            @"maxFPBytesReadPerSample":@(kFrames * 16), @"maxJSONBytesExclusive":@(kMaxJSON),
            @"maxImages":@(kImages), @"imagesObserved":@(gImageTotal),
            @"imageHeadersChecked":@(gImageHeadersChecked), @"maxImageHeadersChecked":@4096,
            @"ownImageUUIDIncluded":@(gOwnImageIncluded), @"nonceCapacity":@(kNonces),
            @"eventsOverwrittenAtLeast":@(requested > kEvents ? requested - kEvents : 0),
            @"eventsContentionDropped":@(gDropped.load(std::memory_order_relaxed) - gDroppedStart),
            @"notificationErrors":@[@(gCommandError), @(gBlankError), @(gLockError)]},
        @"evidence":@"best-effort non-suspending registers and FP chain; not DWARF; concurrent memory may change; no hang verdict",
        @"notificationClock":@"background callback receipt, not physical wake latency; main stages are hook delivery"
    } mutableCopy];
}
static NSString *Encode(NSMutableDictionary *report) {
    // Keep the schema2 array present, and never leave a legacy private worker payload.
    [report removeObjectForKey:@"workerThreads"];
    if (!report[@"workerSnapshots"]) report[@"workerSnapshots"] = @[];
    // Retry order: events, worker snapshots, images, main samples. Five encodings.
    for (unsigned attempt = 0; attempt < 5; ++attempt) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:&error];
        if (data && data.length < kMaxJSON)
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        report[@"serializationError"] = @(data ? 1 : 2);
        report[@"truncated"] = @YES;
        if (attempt == 0) { report[@"events"] = @[]; report[@"eventsDiscarded"] = @YES; }
        else if (attempt == 1) {
            report[@"workerSnapshots"] = @[]; report[@"workerSnapshotsDiscarded"] = @YES;
            [report removeObjectForKey:@"workerThreads"];
        } else if (attempt == 2) {
            report[@"images"] = @[]; report[@"imagesDiscarded"] = @YES;
            NSMutableDictionary *limits = [report[@"limits"] mutableCopy];
            limits[@"ownImageUUIDIncluded"] = @NO; report[@"limits"] = limits;
        } else if (attempt == 3) { report[@"samples"] = @[]; report[@"samplesDiscarded"] = @YES; }
    }
    return nil;
}
static void Publish(NSMutableDictionary *report) {
    NSString *json = Encode(report);
    if (!json) return;
    CFPreferencesSetAppValue(CFSTR("report"), (__bridge CFStringRef)json,
                             CFSTR("com.82flex.letterpress.diagnostics"));
    if (!CFPreferencesAppSynchronize(CFSTR("com.82flex.letterpress.diagnostics"))) {
        report[@"captureStatusBeforePersistenceError"] = report[@"status"] ?: @"error";
        report[@"status"] = @"error";
        report[@"persistenceError"] = @1;
        json = Encode(report);
        if (json) {
            CFPreferencesSetAppValue(CFSTR("report"), (__bridge CFStringRef)json,
                                     CFSTR("com.82flex.letterpress.diagnostics"));
            // A failed retry cannot be made durably observable by this process.
            (void)CFPreferencesAppSynchronize(CFSTR("com.82flex.letterpress.diagnostics"));
        }
    }
    gPublished = report;
}

static void Finish(uint64_t reason) {
    if (!gRecording) return;
    if (!gAckReported && gAckEpoch.load(std::memory_order_acquire) == gEpoch) {
        uint64_t ack = gAckTime.load(std::memory_order_relaxed);
        if (ack >= gStart) {
            gQueueDelay = NS(ack - gStart); gAckReported = true;
            EventAt(gEpoch, ack, 201, gQueueDelay, 0);
        }
    }
    EventNow(202, reason, 0);
    gActive.store(0, std::memory_order_release);
    gRecording = false;
    if (gTimer) { dispatch_source_cancel(gTimer); gTimer = nil; }
    gEndUnix = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
    gImageReport = CollectImages();
    Publish(Report(@"completed", true));
}
static void Skip(uint32_t reason, uint64_t detail) noexcept {
    static uint32_t lastReason;
    if (reason < 10) ++gSkip[reason];
    // Summarize reason transitions, not 20 events/s or per-run-loop-turn events.
    if (reason != lastReason || reason == 6) EventNow(220, reason, detail);
    lastReason = reason;
}
static void Tick() {
    if (!gRecording) return;
    uint64_t now = Clock();
    uint64_t gap = NS(now - gLastTick); gLastTick = now;
    uint64_t busy = gBusy.load(std::memory_order_acquire);
    if (gap > 300 * kMS) {
        // Do not count sleep or a delayed collector as observed main-thread work.
        // Resume only after a fresh 250ms window of regular background ticks;
        // retaining the inherited busy stamp must not hide the whole wake stall.
        gObservationStart = now; Skip(6, gap);
        if (NS(now - gStart) >= 90 * kSecond) Finish(1);
        return;
    }
    if (NS(now - gStart) >= 90 * kSecond) { Finish(1); return; }
    if (!gAckReported && gAckEpoch.load(std::memory_order_acquire) == gEpoch) {
        uint64_t ack = gAckTime.load(std::memory_order_relaxed);
        if (ack >= gStart) {
            gQueueDelay = NS(ack - gStart); gAckReported = true;
            EventAt(gEpoch, ack, 201, gQueueDelay, 0);
        }
    }
    if (!gObserverSeen.load(std::memory_order_acquire)) { Skip(9, 0); return; }
    if (!busy || busy > now) { Skip(1, 0); return; }
    // Known blank is evidence, not a veto: the target scene timeout occurs
    // BEFORE unblank. These samples never by themselves constitute a hang verdict.
    if (busy == gSuppressedBusy) { Skip(7, 0); return; }
    uint64_t observedSince = busy > gObservationStart ? busy : gObservationStart;
    if (NS(now - observedSince) <= 250 * kMS) { Skip(2, 0); return; }
    if (gSampleCount >= kSamples) { Skip(5, gSampleCount); return; }
    if (busy != gBusySampled) { gBusySampled = busy; gPerBusy = 0; }
    if (gPerBusy >= 6) { Skip(4, gPerBusy); return; }
    if (gLastSample && NS(now - gLastSample) < 250 * kMS) { Skip(3, 0); return; }
    gLastSample = now; ++gPerBusy;
    Capture(now, busy, observedSince);
    EventAt(gEpoch, now, 221, gSampleCount - 1, NS(now - observedSince));
    // Failed Mach queries are evidence, never a same-busy retry storm.
    if (gSamples[gSampleCount - 1].error == 1 || gSamples[gSampleCount - 1].error == 2)
        gSuppressedBusy = busy;
    MaybeCaptureWorkers(); // never alters/suppresses the just-recorded main sample
}
static void Start(NSString *requestID) {
    gEpoch = ++gEpochCounter;
    if (!gEpoch) gEpoch = ++gEpochCounter;
    gRequestID = requestID; gStart = Clock(); gLastTick = gStart; gObservationStart = gStart;
    gStartUnix = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
    gEndUnix = 0; gLastSample = 0; gBusySampled = 0; gSuppressedBusy = 0;
    gSampleCount = 0; gPerBusy = 0; gAckReported = false; gQueueDelay = 0;
    gWorkerSnapshotCount = 0; gWorkerScanCursor = 0; gWorkerAttemptedBusy = 0;
    std::memset(gWorkerSnapshots, 0, sizeof(gWorkerSnapshots));
    gImageReport = nil; gImageTotal = 0; gImageHeadersChecked = 0; gOwnImageIncluded = false;
    std::memset(gSkip, 0, sizeof(gSkip));
    gStartTicket = gTicket.load(std::memory_order_acquire);
    gDroppedStart = gDropped.load(std::memory_order_relaxed);
    gDeadline.store(gStart + (uint64_t)(((__uint128_t)90 * kSecond * gTimebase.denom) / gTimebase.numer),
                    std::memory_order_relaxed);
    gRecording = true; gActive.store(gEpoch, std::memory_order_release);
    EventNow(200, 0, 0);
    // Durable background acknowledgement is independent of main queue progress.
    Publish(Report(@"recording", false));
    const uint64_t epoch = gEpoch;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gActive.load(std::memory_order_acquire) != epoch) return;
        gAckTime.store(Clock(), std::memory_order_relaxed);
        gAckEpoch.store(epoch, std::memory_order_release);
    });
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    if (!gTimer) {
        gActive.store(0, std::memory_order_release); gRecording = false;
        gEndUnix = [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970;
        NSMutableDictionary *r = Report(@"error", true); r[@"errorCode"] = @20; Publish(r); return;
    }
    dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 50 * kMS), 50 * kMS, 5 * kMS);
    dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { if (gEpoch == epoch) Tick(); } });
    dispatch_resume(gTimer);
}
static double UnixNow() { return [NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970; }
static void Reject(NSString *requestID, uint32_t error) {
    NSMutableDictionary *r;
    if (gPublished) r = [gPublished mutableCopy];
    else {
        gRequestID = requestID ?: @"";
        r = Report(@"error", false);
    }
    r[@"lastCommand"] = @{@"requestID":requestID ?: @"", @"status":@"rejected",
                           @"reason":error == 37 ? @"busy" : @"invalid_request",
                           @"reasonCode":@(error), @"receivedAtUnix":@(UnixNow())};
    // Never replace the root identity/evidence of a recording or prior report.
    Publish(r);
}
// Error codes: 30=sync/read, 31=shape/type, 32=UUID, 33=stale/future,
// 34=replay, 35=nonce capacity, 36=unknown command, 37=busy, 38=not recording.
static void Command() {
    if (!CFPreferencesAppSynchronize(CFSTR("com.82flex.letterpress.diagnostics"))) { Reject(nil, 30); return; }
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("request"), CFSTR("com.82flex.letterpress.diagnostics"));
    id request = CFBridgingRelease(value);
    if (![request isKindOfClass:[NSDictionary class]]) { Reject(nil, 31); return; }
    id command = request[@"command"], rawID = request[@"requestID"], issued = request[@"issuedAtUnix"];
    if (![command isKindOfClass:[NSString class]] || ![rawID isKindOfClass:[NSString class]] ||
        ![issued isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)issued) == CFBooleanGetTypeID()) {
        Reject(nil, 31); return;
    }
    if ([rawID length] != 36) { Reject(nil, 32); return; }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:rawID];
    if (!uuid) { Reject(nil, 32); return; }
    NSString *requestID = uuid.UUIDString.lowercaseString;
    double stamp = [issued doubleValue], now = UnixNow();
    if (!std::isfinite(stamp) || stamp > now + 5.0 || now - stamp > 60.0) { Reject(requestID, 33); return; }
    const char *key = requestID.UTF8String;
    int freeSlot = -1;
    for (uint32_t i = 0; i < kNonces; ++i) {
        if (gNonces[i].expires <= now) { if (freeSlot < 0) freeSlot = (int)i; continue; }
        if (!std::strcmp(gNonces[i].uuid, key)) { Reject(requestID, 34); return; }
    }
    if (freeSlot < 0) { Reject(requestID, 35); return; }
    std::memcpy(gNonces[freeSlot].uuid, key, 37);
    gNonces[freeSlot].expires = now + 66.0; // covers full freshness + tolerated future skew
    if ([command isEqualToString:@"start"]) {
        if (gRecording) Reject(requestID, 37); else Start(requestID);
    } else if ([command isEqualToString:@"stop"]) {
        if (!gRecording) { Reject(requestID, 38); return; }
        Finish(2);
        NSMutableDictionary *r = [gPublished mutableCopy];
        r[@"lastCommand"] = @{@"requestID":requestID, @"status":@"accepted", @"reasonCode":@0};
        Publish(r);
    } else if ([command isEqualToString:@"clear"]) {
        gActive.store(0, std::memory_order_release); gRecording = false;
        if (gTimer) { dispatch_source_cancel(gTimer); gTimer = nil; }
        gRequestID = requestID; gImageReport = nil; gImageTotal = 0;
        gStart = 0; gStartUnix = 0; gEndUnix = now; gSampleCount = 0;
        gAckReported = false; gQueueDelay = 0; std::memset(gSkip, 0, sizeof(gSkip));
        std::memset(gSamples, 0, sizeof(gSamples));
        gWorkerSnapshotCount = 0; gWorkerScanCursor = 0; gWorkerAttemptedBusy = 0;
        std::memset(gWorkerSnapshots, 0, sizeof(gWorkerSnapshots));
        gImageHeadersChecked = 0; gOwnImageIncluded = false;
        gEpoch = 0; gStartTicket = gTicket.load(std::memory_order_relaxed);
        gDroppedStart = gDropped.load(std::memory_order_relaxed);
        Publish(Report(@"cleared", false));
    } else Reject(requestID, 36);
}

static void Bootstrap() {
    // No constructor: explicit opt-in install, process-gated before subscriptions.
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"] ||
        ![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        if (gMainThread != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), gMainThread);
        return;
    }
    if (mach_timebase_info(&gTimebase) != KERN_SUCCESS || !gTimebase.denom) return;
    gQueue = dispatch_queue_create("com.82flex.letterpress.diagnostics", DISPATCH_QUEUE_SERIAL);
    if (!gQueue) return;
    dispatch_async(gQueue, ^{ @autoreleasepool {
        CFRunLoopObserverContext context = {0, nullptr, nullptr, nullptr, nullptr};
        gObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
            kCFRunLoopEntry | kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting | kCFRunLoopExit,
            true, 0, RunLoop, &context);
        if (gObserver) CFRunLoopAddObserver(CFRunLoopGetMain(), gObserver, kCFRunLoopCommonModes);
        gBlankError = notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &gBlankToken, gQueue, ^(int token) {
            @autoreleasepool {
                uint64_t received = Clock(), epoch = gActive.load(std::memory_order_acquire);
                uint64_t state = 0; uint32_t error = notify_get_state(token, &state);
                gBlankKnown = error == NOTIFY_STATUS_OK; gBlankState = state;
                EventAt(epoch, received, 210, state, error);
            }
        });
        gLockError = notify_register_dispatch("com.apple.springboard.lockstate", &gLockToken, gQueue, ^(int token) {
            @autoreleasepool {
                uint64_t received = Clock(), epoch = gActive.load(std::memory_order_acquire);
                uint64_t state = 0; uint32_t error = notify_get_state(token, &state);
                gLockKnown = error == NOTIFY_STATUS_OK; gLockState = state;
                EventAt(epoch, received, 211, state, error);
            }
        });
        if (gBlankError == NOTIFY_STATUS_OK)
            gBlankKnown = notify_get_state(gBlankToken, &gBlankState) == NOTIFY_STATUS_OK;
        if (gLockError == NOTIFY_STATUS_OK)
            gLockKnown = notify_get_state(gLockToken, &gLockState) == NOTIFY_STATUS_OK;
        gCommandError = notify_register_dispatch("com.82flex.letterpress.diagnostics.command", &gCommandToken, gQueue, ^(int) {
            @autoreleasepool { Command(); }
        });
        // Do not execute a persisted request on install/restart. A fresh notify
        // and explicit freshness/nonce validation are required for every capture.
    } });
}
} // namespace

extern "C" void LPSBWakeDiagnosticsInstall(void) {
    if (!pthread_main_np()) return;
    uint32_t expected = 0;
    if (!gInstalled.compare_exchange_strong(expected, 1, std::memory_order_acq_rel)) return;
    pthread_t main = pthread_self();
    uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(main);
    size_t size = pthread_get_stacksize_np(main);
    if (high && size && size <= high) { gStackHigh = high; gStackLow = high - size; }
    gMainThread = mach_thread_self(); // exactly one retained send right for process lifetime
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { Bootstrap(); } });
}
extern "C" void LPSBWakeDiagnosticMark(uint32_t code, uint64_t a, uint64_t b) {
    uint64_t epoch = gActive.load(std::memory_order_acquire);
    if (!epoch) return;
    uint64_t now = Clock();
    if (now >= gDeadline.load(std::memory_order_relaxed)) return;
    gStage.store(code, std::memory_order_relaxed); gStageTime.store(now, std::memory_order_relaxed);
    EventAt(epoch, now, code, a, b);
}
extern "C" void LPSBWakeDiagnosticWindow(uint64_t context, uint64_t scene, uint64_t flags) {
    gWindowSeq.fetch_add(1, std::memory_order_acq_rel);
    gContext.store(context, std::memory_order_relaxed);
    gScene.store(scene, std::memory_order_relaxed); gFlags.store(flags, std::memory_order_relaxed);
    gWindowSeq.fetch_add(1, std::memory_order_release);
    uint64_t epoch = gActive.load(std::memory_order_acquire);
    if (!epoch) return;
    uint64_t now = Clock();
    EventAt(epoch, now, 100, context, scene); EventAt(epoch, now, 101, flags, 0);
}
