# AltTab Architectural Review and Refactoring Proposal

This review focuses on lifecycle safety, global mutable state, AX observer registration, concurrency boundaries, and separation between switcher domain logic and AppKit rendering. The recommendations are intentionally incremental: AltTab is a latency-sensitive AppKit utility with broad macOS compatibility requirements, private API usage, and many real-world AX edge cases.

## 1. Architectural Critique

### What is working well

- The project is correctly AppKit-first. `App` owns the `NSApplicationDelegate` lifecycle, while UI surfaces such as `TilesPanel`, `PreviewPanel`, `TilesView`, settings, permissions, and menu-bar UI stay in AppKit rather than attempting a framework rewrite.
- Startup is gated behind permissions. `SystemPermissions.ensurePermissionsAreGranted()` performs pre-startup checks before `App.continueAppLaunchAfterPermissionsAreGranted()` starts background threads, AX observation, windows, spaces, screens, keyboard handlers, cursor handlers, trackpad handlers, CLI events, and preference observers.
- AX calls are treated as unreliable, expensive IPC. `AXCallScheduler` provides throttling, retry/backoff, bounded operation queues, and unresponsive-pid segregation instead of doing synchronous AX work directly on the main thread.
- Window discovery is resilient by design. The app combines AX notifications with manual reconciliation through `Applications.manuallyRefreshAllWindows()`, `Applications.addMissingWindows()`, `Applications.reviewExistingWindows()`, and `Applications.removeZombieWindows()`.
- Screen recording permission checks avoid passive system prompts during startup. `ScreenRecordingPermission.detect()` uses `CGPreflightScreenCaptureAccess()` first and performs deeper checks only after preflight succeeds.
- Private APIs are used deliberately for product capability rather than accidentally leaking across the whole codebase. Screenshot capture falls back to the private capture path for older macOS and known ScreenCaptureKit regressions.

### Highest-risk architectural issues

#### Critical: unsafe signal and crash handling

Current paths:

- `src/main.swift` installs raw handlers for `SIGTERM` and `SIGTRAP`.
- The signal handler calls `emergencyExit()`.
- `emergencyExit()` calls `setNativeCommandTabEnabled(true)`, prints Swift values, walks `Thread.callStackSymbols`, waits for screenshot captures, sleeps, mutates `App.isTerminating`, logs through `Logger`, and exits.
- `NSSetUncaughtExceptionHandler` calls the same `emergencyExit()` path.
- `App.applicationShouldTerminate(_:)` also calls `makeSureAllCapturesAreFinished()`.

Risk:

Raw POSIX signal handlers may only call async-signal-safe functions. Swift closures, Objective-C/Cocoa APIs, logging, stack symbolization, locks, allocation, sleeps, and AX/screenshot coordination are unsafe in that context. Handling `SIGTRAP` as if the process can be cleaned up is especially dangerous because Swift traps usually indicate undefined or unrecoverable state. This path can deadlock, corrupt process state further, or mask real crash reports.

The good intent is clear: restore native Command-Tab and avoid macOS permission dialogs caused by abandoned screenshot captures. The implementation should move that cleanup to normal termination paths and signal sources, not raw signal handlers.

Severity: Critical because it runs during crash/termination, where correctness matters most and the process is least stable.

#### High: global mutable state concentration across `App`, `Windows`, and `TilesView`

Current paths:

- `App` owns global switcher state: `isTerminating`, `appIsBeingUsed`, `shortcutIndex`, `forceDoNothingOnRelease`, `isFirstSummon`, `isVeryFirstSummon`, `pendingShowSettingsWindow`, and `delayedDisplayScheduled`.
- `App.showUiOrCycleSelection()` mutates session state, records usage, updates screens, starts search, filters windows, selects windows, schedules delayed UI, builds UI, or cycles selection.
- `Windows` owns global domain state: `list`, `selectedWindowIndex`, `selectedWindowTarget`, `hoveredWindowIndex`, `lastFocusedWindowTarget`, `lastWindowActivityType`, `searchQuery`, and search-selection flags.
- `TilesView` owns global UI/rendering state: `scrollView`, `contentView`, `searchField`, `searchMode`, `rows`, `recycledViews`, layout caches, thumbnail layers, and initialization state.
- Keyboard, trackpad, CLI, search, and UI code directly read and write these globals.

Risk:

The current design makes the switcher session an implicit distributed state machine. A single shortcut press can move through `ATShortcut`, `ControlsTab`, `App`, `Windows`, `TilesView`, `TilesPanel`, `KeyRepeatTimer`, `CursorEvents`, and `TrackpadEvents`. Because session state is spread across static properties, invariants such as “the active shortcut index matches the current search session” or “delayed display is still valid for this summon” are not represented in one place.

This also harms tests. The current unit test strategy shadows production globals with mocks, which works for narrow keyboard tests but does not make the real selection/search/session policy easy to test.

Severity: High because this state is hit by high-frequency keyboard, AX, mouse, trackpad, screen, and space events.

#### High: AX observer and run-loop registration idempotency is implicit

Current paths:

- `Application.init` calls `observeEventsIfEligible()`.
- KVO callbacks for `isFinishedLaunching` and `activationPolicy` call `observeEventsIfEligible()` again.
- `Window.init` calls `application.observeEventsIfEligible()` because the app may have timed out earlier.
- `Application.observeEventsIfEligible()` creates `axUiElement` and `axObserver` if needed, then calls `observeEvents()`.
- `Application.observeEvents()` schedules subscriptions and calls `CFRunLoopAddSource(...)` every time it runs.
- `Window.observeEvents()` creates a per-window `AXObserver`, schedules subscriptions, and adds a run-loop source.

Risk:

The project relies on `isReallyFinishedLaunching`, `axObserver == nil`, scheduler keys, and AX behavior to avoid duplication. That is not auditable enough. Repeated `AXObserverAddNotification` calls can return errors, cause noisy logs, or hide missing-subscription bugs. Repeated `CFRunLoopAddSource` calls are also not represented in app state, so future changes can accidentally make registration non-idempotent.

Severity: High because AX event subscription correctness is central to window tracking and because this code is intentionally retried from multiple paths.

#### Medium-high: concurrency safety is conventional rather than enforced

Current paths:

- `BackgroundWork` creates dedicated run-loop threads and operation queues.
- AX events start on a background run loop, then use `AXCallScheduler`, then usually dispatch mutations back to the main thread.
- `Applications.list`, `Windows.list`, `App.appIsBeingUsed`, `App.shortcutIndex`, `WindowCaptureScreenshots.cachedSCWindows`, and many `Window` fields are globally visible mutable state.
- `ActiveWindowCaptures` uses deprecated `OSAtomicIncrement32`, `OSAtomicDecrement32`, and `OSAtomicAdd32`.
- `LabeledOperationQueue` uses `OSAtomic*` for callback counts and declares `@unchecked Sendable`.
- `MissionControl` already needs an `NSLock`, indicating some cross-thread shared state is known.

Risk:

The code usually does the right thing by dispatching UI and list mutations to the main thread, but the boundary is not compiler-enforced. Future changes can read or mutate these globals from queue callbacks with no immediate warning. Deprecated atomics also keep old synchronization APIs in core infrastructure.

Severity: Medium-high because there is already good queue discipline, but the blast radius of a mistake is large.

#### Medium: UI rendering is coupled to window-selection and search policy

Current paths:

- `Windows.shouldDisplay()` combines window visibility with `Search.matches()`.
- `Windows.updateSearchQuery()` mutates query state, search-selection flags, hover state, and sort order.
- `Windows.updateSelectedWindow()` computes selection and mutates global selection state.
- `Windows.updateSelectedAndHoveredWindowIndex()` mutates selection and hover state, resets hover UI, highlights `TilesView`, previews windows, scrolls AppKit views, and triggers VoiceOver.
- `TilesView` owns search field state, search mode, key handling, query propagation, timers, menu state, focus, and UI refresh calls.

Risk:

Search scoring itself is fairly isolated in `src/logic/search/Search.swift`, but the behavior users experience is not: selection policy, preference filtering, search session transitions, and UI effects are blended. This makes it hard to write unit tests for “when the query changes, select the best visible match” without constructing large pieces of UI state.

Severity: Medium because the current behavior works, but it slows future changes and increases regression risk in keyboard/search workflows.

#### Medium: platform strategy is carrying two eras of Swift/macOS

Current paths:

- The project historically supports macOS 10.12.
- Modern APIs are conditionally used, such as ScreenCaptureKit on newer macOS.
- The codebase is still built around static globals, callbacks, `DispatchQueue`, `OperationQueue`, and manual locking.

Risk:

Actors, `@MainActor`, structured concurrency, task cancellation, and Swift Atomics would improve clarity, but a full migration is unrealistic while preserving very old deployment targets. Without a formal platform strategy, the project risks either avoiding modern safety indefinitely or adopting it in isolated places that do not compose.

Severity: Medium because it affects long-term maintainability more than immediate correctness.

## 2. Actionable Refactoring Plan

### Phase 1: safety and lifecycle hardening

Scope:

- Introduce `TerminationController` early in process startup.
- Replace raw `signal { ... }` cleanup with `DispatchSourceSignal` for `SIGTERM` and possibly `SIGINT`.
- Stop intercepting `SIGTRAP` for cleanup. Let crash reporting and the OS record the crash.
- Keep `SIGKILL` documented as impossible to intercept.
- Introduce `AppCleanupCoordinator` as the single idempotent cleanup path for normal termination.
- Move `setNativeCommandTabEnabled(true)` and screenshot-drain behavior into this coordinator.
- Keep raw signal handlers either ignored via `SIG_IGN` for dispatch-source-managed signals or minimal enough to only set an atomic flag if absolutely required.

Expected impact:

- Removes unsafe work from crash/signal contexts.
- Makes normal termination, menu quit, Activity Monitor terminate, benchmark termination, and app restart use one cleanup flow.
- Reduces duplicate cleanup behavior between `main.swift`, `applicationShouldTerminate`, and `applicationWillTerminate`.

Risk:

- Native Command-Tab restoration must remain reliable.
- Screenshot drain must not hang termination indefinitely.
- Force Quit and `SIGKILL` still cannot be cleaned up; documentation should say that plainly.

Validation strategy:

- Add unit tests for cleanup idempotency: calling cleanup twice should restore Command-Tab once and not wait twice.
- Add a test seam around active capture count so timeout behavior can be tested without real screenshots.
- Manually validate menu quit, Cmd-Q, `kill -TERM <pid>`, Activity Monitor quit, app restart, and benchmark termination.
- Verify crash reports still appear for Swift traps instead of being converted into exit code 0.

Migration guidance:

- Do not change permissions behavior in this phase.
- Do not change AX event handling in this phase except for ensuring termination prevents new screenshot captures.
- Keep `makeSureAllCapturesAreFinished()` behavior available, but call it only from safe termination paths.

### Phase 2: observer registration idempotency

Scope:

- Add explicit AX registration state to `Application`:
  - `private var didAttachAXRunLoopSource = false`
  - `private var subscribedAXNotifications = Set<String>()`
  - possibly `private var isSubscribingAXNotifications = false` if retry overlap becomes visible.
- Add equivalent state to `Window` for per-window notification subscriptions.
- Split AX setup into small operations: `ensureAXObjects()`, `attachAXRunLoopSourceIfNeeded()`, `subscribeToAXNotificationsIfNeeded()`.
- Log subscription result per notification when useful, not just for the first notification.
- On app/window removal, remove scheduler entries and, where practical, remove AX notifications or at least mark the object as inactive so pending callbacks are ignored.

Expected impact:

- Repeated KVO, launch, and window-created calls become harmless and auditable.
- AX registration can be tested without relying on hidden AX behavior.
- Future changes will not accidentally add the same run-loop source repeatedly.

Risk:

- Over-eager “already subscribed” flags could mark a failed subscription as successful.
- Some apps are slow to become AX-responsive; first-subscription success currently defines “really finished launching.” Preserve that behavior.

Validation strategy:

- Unit-test repeated `observeEventsIfEligible()` calls using injected AX subscription helpers.
- Exercise slow-launch apps, apps that restore windows on launch, apps that change activation policy, and apps that create windows before subscription succeeds.
- Keep `Applications.manuallyUpdateWindows()` and `Applications.removeZombieWindows()` as backstops.

Migration guidance:

- Do not remove manual window reconciliation just because subscriptions become cleaner.
- Treat AX notifications as lossy hints; the source of truth remains reconciled state from AX and CGWindow queries.

### Phase 3: state isolation

Scope:

- Introduce a single switcher session state object. While deployment remains very old, start with a main-thread-confined class and explicit assertions. When deployment allows, mark it `@MainActor`.
- Move these fields first:
  - `App.appIsBeingUsed`
  - `App.shortcutIndex`
  - `App.forceDoNothingOnRelease`
  - `App.isFirstSummon`
  - `App.isVeryFirstSummon`
  - delayed display generation/token state
- Then move selection/search fields from `Windows`:
  - `selectedWindowIndex`
  - `selectedWindowTarget`
  - `hoveredWindowIndex`
  - `lastFocusedWindowTarget`
  - `lastWindowActivityType`
  - `searchQuery`
  - search-selection flags
- Keep compatibility static accessors during migration so call sites can be converted gradually.

Expected impact:

- The current switcher session becomes explicit instead of spread across `App`, `Windows`, and `TilesView`.
- Delayed display can use generation tokens rather than increment/decrement counters.
- Tests can construct session state directly rather than mocking a fake global app.

Risk:

- Shortcut release behavior is timing-sensitive.
- Search-on-release and focus-on-release modes rely on `forceDoNothingOnRelease` being updated at exactly the right time.
- Trackpad and keyboard paths both drive the same state and must remain consistent.

Validation strategy:

- Extend keyboard tests around:
  - focus on release
  - search on release
  - hold shortcut release after switching shortcut index
  - delayed display cancellation
  - trackpad-triggered show/cycle/focus flows where possible
- Add invariant checks in debug builds: if the switcher is hidden, search mode should be off, delayed show tokens should be invalid, and preview should be hidden unless explicitly preserved.

Migration guidance:

- Keep external behavior unchanged by introducing state object behind existing `App`/`Windows` methods first.
- Move one cluster of fields at a time; do not combine this phase with UI rewrites.

### Phase 4: UI/domain decoupling

Scope:

- Extract pure or mostly pure services:
  - `WindowFilteringPolicy`
  - `WindowSortingPolicy`
  - `WindowSelectionPolicy`
  - `SearchSessionPolicy`
- Pass in explicit inputs: window snapshots, active shortcut index, preference snapshot, search query, focused target, previous selection, hover state, and window order.
- Return explicit outputs: visible windows, sorted order, selected target/index, hover target/index, and UI effects such as highlight, scroll, preview, or VoiceOver.
- Keep `TilesView` focused on rendering, search field wiring, first responder behavior, and forwarding user interaction.
- Keep `App` or a new coordinator focused on orchestration.

Expected impact:

- Selection and search behavior can be tested without AppKit surfaces.
- `Windows` becomes a state/model manager instead of a model, domain service, and UI presenter at once.
- UI refresh paths become clearer: domain result first, AppKit effects second.

Risk:

- Sorting and filtering preferences are dense and user-visible.
- `onlyShowApplications`, tabbed windows, minimized/fullscreen/hidden buckets, spaces, screens, and active/non-active app preferences interact in subtle ways.

Validation strategy:

- Add table-driven tests for filtering and sorting preferences.
- Add tests for search query transitions:
  - empty to non-empty selects best match
  - non-empty to empty restores default selection
  - changed query preserves or updates target according to current behavior
- Add tests for focus changes while the switcher is open.
- Add tests for no-visible-window behavior.

Migration guidance:

- Start by extracting `Windows.shouldDisplay`, sort, and selected-index calculation into policy functions while leaving current static methods as wrappers.
- Only after tests cover policy behavior should `TilesView` calls be removed from `Windows.updateSelectedAndHoveredWindowIndex()`.

### Phase 5: concurrency modernization and platform strategy

Scope:

- Replace deprecated `OSAtomic*` usage in `ActiveWindowCaptures` and `LabeledOperationQueue`.
  - If adding Swift Atomics is acceptable, use `ManagedAtomic<Int32>`.
  - If avoiding a new dependency is preferable, use a tiny `NSLock`-protected counter.
- Mark UI mutation surfaces as main-thread-only. If `@MainActor` is not viable for the current deployment target, add debug assertions first.
- Introduce protocols for AX scheduling, screenshot capture, and permission checking before actor migration.
- When deployment target allows, migrate session/coordinator services to `@MainActor` and consider actors for high-contention shared state.
- Keep `AXCallScheduler` queue-based until actor overhead and cancellation semantics are proven not to hurt latency.

Expected impact:

- Removes deprecated synchronization primitives.
- Makes concurrency boundaries explicit before changing execution mechanics.
- Reduces accidental background mutation of UI/session state.

Risk:

- A broad async/await migration may be blocked by historical deployment support.
- Actor isolation can add overhead or create inconvenient hops in high-frequency paths if introduced too early.

Validation strategy:

- Run `scripts/build_app_debug.sh` after each step.
- Run the app with `open DerivedData/Build/Products/Debug/AltTab.app` after successful builds.
- Use debug queue/thread instrumentation to compare thread counts and active operation counts.
- Stress with rapid keyboard repeats, AX-heavy apps, Mission Control transitions, display changes, and screen recording enabled/disabled.

Migration guidance:

- Treat deployment target uplift as a separate product/platform decision.
- Do not block safety refactors on a future async/await migration.
- Prefer main-thread assertions and protocol seams now; add actors later where they replace real shared mutable state.

## 3. Code Comparison

### A. Process termination and signal routing

Before:

```swift
[SIGTERM, SIGTRAP].forEach {
    signal($0) { s in
        emergencyExit("Exiting after receiving signal", s)
    }
}

NSSetUncaughtExceptionHandler { exception in
    emergencyExit("Exiting after receiving uncaught NSException", exception)
}

fileprivate func emergencyExit(_ logs: Any?...) {
    setNativeCommandTabEnabled(true)
    print(logs)
    printStackTrace()
    makeSureAllCapturesAreFinished()
    exit(0)
}
```

After, directionally:

```swift
final class TerminationController {
    private var sources = [DispatchSourceSignal]()

    func start() {
        installSource(for: SIGTERM)
        installSource(for: SIGINT)
    }

    private func installSource(for signalNumber: Int32) {
        Darwin.signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            AppCleanupCoordinator.shared.beginTermination(reason: .signal(signalNumber))
        }
        source.resume()
        sources.append(source)
    }
}

final class AppCleanupCoordinator {
    static let shared = AppCleanupCoordinator()
    private var didBegin = false

    func beginTermination(reason: TerminationReason) {
        guard !didBegin else { return }
        didBegin = true
        App.isTerminating = true
        setNativeCommandTabEnabled(true)
        WindowCaptureDrain.shared.waitBrieflyForActiveCaptures()
        App.shared.reply(toApplicationShouldTerminate: true)
    }
}
```

Why this is safer:

- The raw signal path no longer executes Swift/Cocoa cleanup.
- Normal termination becomes idempotent and auditable.
- Swift traps and Objective-C exceptions can be reported as crashes instead of being turned into successful exits.
- Screenshot drain remains available, but only from safe contexts.

### B. AX observer registration idempotency

Before:

```swift
func observeEventsIfEligible() {
    if runningApplication.activationPolicy != .prohibited && !isReallyFinishedLaunching {
        if axUiElement == nil {
            axUiElement = AXUIElementCreateApplication(pid)
        }
        if axObserver == nil {
            AXObserverCreate(pid, AccessibilityEvents.axObserverCallback, &axObserver)
        }
        observeEvents()
    }
}

private func observeEvents() {
    guard let axObserver else { return }
    AXCallScheduler.shared.schedule(key: "sub-app-\(pid)", context: debugId, pid: pid) { [weak self] in
        guard let self, !self.isReallyFinishedLaunching else { return }
        if try self.axUiElement!.subscribeToNotification(axObserver, Application.notifications.first!) {
            self.isReallyFinishedLaunching = true
            for notification in Application.notifications.dropFirst() {
                AXCallScheduler.shared.schedule(key: "sub-app-\(self.pid)-\(notification)", context: self.debugId, pid: self.pid) { [weak self] in
                    try self?.axUiElement!.subscribeToNotification(axObserver, notification)
                }
            }
        }
    }
    CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
}
```

After, directionally:

```swift
private var didAttachAXRunLoopSource = false
private var subscribedAXNotifications = Set<String>()

func observeEventsIfEligible() {
    guard runningApplication.activationPolicy != .prohibited, !isReallyFinishedLaunching else { return }
    ensureAXObjects()
    attachAXRunLoopSourceIfNeeded()
    subscribeToAXNotificationsIfNeeded()
}

private func ensureAXObjects() {
    if axUiElement == nil {
        axUiElement = AXUIElementCreateApplication(pid)
    }
    if axObserver == nil {
        AXObserverCreate(pid, AccessibilityEvents.axObserverCallback, &axObserver)
    }
}

private func attachAXRunLoopSourceIfNeeded() {
    guard !didAttachAXRunLoopSource, let axObserver else { return }
    CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
    didAttachAXRunLoopSource = true
}

private func subscribeToAXNotificationsIfNeeded() {
    for notification in Application.notifications where !subscribedAXNotifications.contains(notification) {
        scheduleSubscription(notification)
    }
}
```

Why this is safer:

- Repeated KVO and window-created retries become explicit no-ops where appropriate.
- Run-loop attachment is separated from AX notification subscription.
- Failed subscriptions can remain retryable instead of accidentally being marked done.
- The current manual refresh backstop can stay intact.

### C. Global switcher state orchestration

Before:

```swift
class App: AppCenterApplication {
    static var appIsBeingUsed = false
    static var shortcutIndex = 0
    static var forceDoNothingOnRelease = false
    private static var isFirstSummon = true

    static func showUiOrCycleSelection(_ shortcutIndex: Int, _ forceDoNothingOnRelease_: Bool) {
        forceDoNothingOnRelease = forceDoNothingOnRelease_
        appIsBeingUsed = true
        UsageStats.recordTrigger(shortcutIndex)
        if isFirstSummon || shortcutIndex != App.shortcutIndex {
            NSScreen.updatePreferred()
            isFirstSummon = false
            App.shortcutIndex = shortcutIndex
            TilesView.startSearchSession(Preferences.shortcutStyle == .searchOnRelease)
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            Windows.setInitialSelectedAndHoveredWindowIndex()
            buildUiAndShowPanel()
        } else {
            cycleSelection(.leading)
            KeyRepeatTimer.startRepeatingKeyNextWindow()
        }
    }
}
```

After, directionally:

```swift
final class SwitcherSessionState {
    var isUsingSwitcher = false
    var activeShortcutIndex = 0
    var forceDoNothingOnRelease = false
    var isFirstSummon = true
    var summonGeneration = 0

    func beginSummon(shortcutIndex: Int, forceDoNothingOnRelease: Bool) -> SummonDecision {
        self.forceDoNothingOnRelease = forceDoNothingOnRelease
        isUsingSwitcher = true
        summonGeneration += 1
        let shouldBuild = isFirstSummon || shortcutIndex != activeShortcutIndex
        isFirstSummon = false
        activeShortcutIndex = shortcutIndex
        return shouldBuild ? .buildUi(generation: summonGeneration) : .cycleSelection
    }
}

final class AppCoordinator {
    private let session: SwitcherSessionState
    private let selectionPolicy: WindowSelectionPolicy
    private let ui: SwitcherUI

    func showOrCycle(shortcutIndex: Int, forceDoNothingOnRelease: Bool) {
        switch session.beginSummon(shortcutIndex: shortcutIndex, forceDoNothingOnRelease: forceDoNothingOnRelease) {
        case .buildUi(let generation):
            buildUiForCurrentSession(generation: generation)
        case .cycleSelection:
            cycleSelection(.leading)
        }
    }
}
```

Why this is safer:

- Session invariants live in one object.
- Delayed display can validate a generation token instead of relying on `delayedDisplayScheduled` arithmetic.
- Tests can exercise summon decisions without AppKit.
- Static wrappers can remain during migration so the change is incremental.

### D. Selection/search domain separated from AppKit effects

Before:

```swift
static func updateSelectedAndHoveredWindowIndex(_ newIndex: Int, _ fromMouse: Bool = false) {
    guard newIndex >= 0 && newIndex < list.count else { return }
    guard shouldDisplay(list[newIndex]) else { return }
    if !fromMouse {
        TilesView.thumbnailOverView.resetHoveredWindow()
    }
    let oldIndex = selectedWindowIndex
    selectedWindowIndex = newIndex
    selectedWindowTarget = list[newIndex].id
    TilesView.highlight(oldIndex)
    previewSelectedWindowIfNeeded()
    TilesView.highlight(selectedWindowIndex)
    let focusedView = TilesView.recycledViews[selectedWindowIndex]
    TilesView.scrollView.contentView.scrollToVisible(focusedView.frame)
    voiceOverWindow(selectedWindowIndex)
}
```

After, directionally:

```swift
struct WindowSelectionState {
    var selectedIndex: Int
    var selectedTarget: String?
    var hoveredIndex: Int?
    var lastActivity: WindowActivityType
}

struct WindowSelectionResult {
    var state: WindowSelectionState
    var effects: [WindowSelectionEffect]
}

struct WindowSelectionPolicy {
    func select(index: Int, fromMouse: Bool, windows: [WindowSnapshot], state: WindowSelectionState) -> WindowSelectionResult? {
        guard windows.indices.contains(index), windows[index].isVisible else { return nil }
        var next = state
        let previous = next.selectedIndex
        next.selectedIndex = index
        next.selectedTarget = windows[index].id
        next.lastActivity = fromMouse ? .hover : .focus
        return WindowSelectionResult(state: next, effects: [.highlight(previous), .highlight(index), .preview(index), .scroll(index), .voiceOver(index)])
    }
}

final class TilesPresenter {
    func apply(_ result: WindowSelectionResult) {
        for effect in result.effects {
            apply(effect)
        }
    }
}
```

Why this is safer:

- The policy can be unit-tested with snapshots.
- AppKit operations stay in the presenter.
- Search, filtering, selection restoration, hover, preview, scroll, and VoiceOver effects become visible outputs instead of hidden side effects.

### E. Deprecated atomics replacement

Before:

```swift
class ActiveWindowCaptures {
    private static var _count: Int32 = 0

    static func increment() { OSAtomicIncrement32(&_count) }
    static func decrement() { OSAtomicDecrement32(&_count) }
    static func value() -> Int { Int(OSAtomicAdd32(0, &_count)) }
}
```

After, no new dependency:

```swift
final class ActiveWindowCaptureCounter {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        count -= 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
```

After, with Swift Atomics if dependency policy allows:

```swift
import Atomics

final class ActiveWindowCaptureCounter {
    private let count = ManagedAtomic<Int>(0)

    func increment() {
        count.wrappingIncrement(ordering: .relaxed)
    }

    func decrement() {
        count.wrappingDecrement(ordering: .relaxed)
    }

    func value() -> Int {
        count.load(ordering: .relaxed)
    }
}
```

Why this is safer:

- Removes deprecated `OSAtomic*` APIs.
- Encapsulates synchronization behind a small type.
- Makes the counter injectable for termination tests.

## Recommended implementation order

1. Add `AppCleanupCoordinator` and `TerminationController`; remove unsafe signal cleanup.
2. Make AX observer registration explicitly idempotent for `Application`.
3. Make AX observer registration explicitly idempotent for `Window`.
4. Replace `ActiveWindowCaptures` and `LabeledOperationQueue` deprecated atomics.
5. Introduce `SwitcherSessionState` behind current static wrappers.
6. Move delayed-display generation and first-summon state into `SwitcherSessionState`.
7. Extract filtering and sorting policy from `Windows` with tests.
8. Extract selection policy from `Windows` with tests.
9. Move AppKit effects from `Windows` to a presenter/coordinator.
10. Decide platform uplift strategy for `@MainActor`, actors, and structured concurrency.

## Testing and validation checklist

- Build with `scripts/build_app_debug.sh` after implementation steps.
- Launch with `open DerivedData/Build/Products/Debug/AltTab.app` after successful builds.
- Verify Accessibility permission flow still prompts only on user action.
- Verify Screen Recording permission checks do not create passive prompts during startup.
- Exercise menu quit, Cmd-Q, Activity Monitor terminate, `kill -TERM`, restart, and benchmark termination.
- Stress rapid keyboard switching, key repeat, search-on-release, focus-on-release, trackpad gestures, and CLI `--show`.
- Exercise slow-launching apps, apps with restored windows, minimized windows, fullscreen windows, hidden apps, tabbed windows, Mission Control, multiple spaces, and multiple displays.
- Compare CPU/thread/queue behavior before and after AX and concurrency changes.# AltTab Architectural Review

This review focuses on the current AppKit-based AltTab architecture, especially process lifecycle safety, global switcher state, AX observer registration, concurrency boundaries, and separation between window-selection/search logic and UI rendering.

## 1. Architectural Critique

### What is working well

- The app has a pragmatic AppKit-first shape and avoids a costly SwiftUI rewrite. The launch sequence in `src/ui/App.swift` is direct, and heavy startup work is gated behind permissions through `continueAppLaunchAfterPermissionsAreGranted`.
- AX load is already treated as hostile and expensive. `src/logic/AXCallScheduler.swift` provides throttling, retry/backoff, unresponsive-pid segregation, and bounded queues instead of issuing blocking AX calls directly from UI paths.
- Window discovery is intentionally redundant. AX subscriptions are backed by manual reconciliation in `Applications.manuallyRefreshAllWindows`, `Applications.addMissingWindows`, `Applications.reviewExistingWindows`, and `Applications.removeZombieWindows`. That is the right posture for macOS AX, where notifications are incomplete in real-world apps.
- Permission checks are cautious. Screen-recording checks avoid passive system prompts on startup, and Accessibility checks use `AXIsProcessTrustedWithOptions` without prompting during passive polling.
- The project already has useful low-level performance instincts: dedicated run-loop threads for APIs that require them, bounded operation queues, thumbnail capture guards, and app/window update throttlers.

### Highest-risk architectural issues

#### 1. Critical: raw crash/signal handling does unsafe work

`src/main.swift` installs raw handlers for `SIGTERM` and `SIGTRAP`, then calls `emergencyExit`. That path performs Swift closure execution, logging/printing, stack walking, App state mutation, sleep loops, screenshot-count polling, and `exit(0)`.

This is unsafe from a POSIX signal handler. Most of that work is not async-signal-safe. It can deadlock, corrupt runtime state, or mask crashes as clean exits. Handling `SIGTRAP` this way is especially risky because Swift traps are not recoverable control flow.

Related paths:

- `src/main.swift`: `signal`, `NSSetUncaughtExceptionHandler`, `emergencyExit`, `makeSureAllCapturesAreFinished`
- `src/ui/App.swift`: `applicationShouldTerminate`, `applicationWillTerminate`
- `src/logic/events/WindowCaptureEvents.swift`: `ActiveWindowCaptures`

#### 2. High: switcher session state is global and cross-cutting

The current switcher session is spread across static mutable state:

- `App.appIsBeingUsed`, `App.shortcutIndex`, `App.forceDoNothingOnRelease`, first-summon flags, delayed display counters
- `Windows.selectedWindowIndex`, `Windows.selectedWindowTarget`, `Windows.hoveredWindowIndex`, search query and search-selection flags
- `TilesView.searchMode`, recycled tile views, layout caches, search field state

`App.showUiOrCycleSelection` mutates session state, records usage, updates screens, sorts windows, starts search mode, filters windows, schedules delayed UI display, builds UI, and starts key-repeat behavior. `Windows.updateSelectedAndHoveredWindowIndex` mutates selection state and directly drives AppKit rendering, previews, scrolling, and VoiceOver.

This makes behavior highly dependent on event order. It also makes tests rely on mock classes that shadow global state instead of testing the real domain logic.

Related paths:

- `src/ui/App.swift`: `hideUi`, `showUiOrCycleSelection`, `refreshUi`, `buildUiAndShowPanel`
- `src/logic/Windows.swift`: selection, filtering, sorting, search state
- `src/ui/main-window/TilesView.swift`: search session and rendering state
- `unit-tests/Mocks.swift`: test-only global stand-ins for `App`, `TilesView`, and `TilesPanel`

#### 3. High: AX observer registration is not explicitly idempotent

`Application.observeEventsIfEligible` can be called from initialization, KVO changes, and `Window.init`. It creates AX objects if needed, then calls `observeEvents`. `observeEvents` schedules notification subscriptions and adds the AX observer run-loop source each time it is called.

`Window.observeEvents` creates a per-window observer, subscribes to notifications, and adds a run-loop source, but it has no explicit subscription state or source-attachment state.

The current code may work most of the time because AX APIs reject or tolerate duplicates, and because the scheduler throttles some repeated work. However, the architecture does not make idempotency auditable. A future change could accidentally increase duplicate subscriptions, repeated source attachment, or missed cleanup.

Related paths:

- `src/logic/Application.swift`: `observeEventsIfEligible`, `observeEvents`
- `src/logic/Window.swift`: `observeEvents`
- `src/api-wrappers/AXUIElement.swift`: `subscribeToNotification`
- `src/logic/Applications.swift`: app/window removal and scheduler-entry cleanup

#### 4. Medium-high: concurrency safety is mostly conventional, not enforced

The code often returns to the main queue before mutating UI or global window state, which is good. But the invariant is implicit. Important state is globally readable and writable, and only some shared structures use locks.

Examples:

- `Windows.list`, `Applications.list`, `Applications.frontmostPid`, and `App.appIsBeingUsed` are static mutable state.
- `WindowCaptureScreenshots.cachedSCWindows` is updated from screenshot/background queues and read elsewhere.
- `ActiveWindowCaptures` uses deprecated `OSAtomic*` APIs.
- `LabeledOperationQueue` uses `@unchecked Sendable`, which is understandable but expands the trust boundary.

Related paths:

- `src/logic/BackgroundWork.swift`: dedicated threads, operation queues, deprecated atomics in queue callback tracking
- `src/logic/events/WindowCaptureEvents.swift`: capture cache and `ActiveWindowCaptures`
- `src/logic/AXCallScheduler.swift`: explicit locking around scheduler state
- `src/api-wrappers/MissionControl.swift`: explicit lock around Mission Control state

#### 5. Medium: UI rendering is coupled to selection and search domain policy

Search scoring is reasonably isolated in `src/logic/search/Search.swift`, but the policy around which windows are visible, which window should be selected, how selection reacts to search changes, and how focus changes while the switcher is open is embedded in `Windows` and directly calls AppKit-facing `TilesView` methods.

This makes critical behavior hard to test without constructing UI state. It also means small UI changes can accidentally change selection semantics.

Related paths:

- `src/logic/Windows.swift`: filtering, sorting, selection, hover, preview, VoiceOver, tile highlighting
- `src/ui/main-window/TilesView.swift`: search mode, query update, refresh calls, key-repeat stop/start
- `src/logic/search/Search.swift`: reusable search scoring core

## 2. Actionable Refactoring Plan

### Phase 1: Safety and lifecycle hardening

Scope:

- Introduce a `TerminationController` for signal routing.
- Stop treating `SIGTRAP` as a recoverable cleanup path.
- Use `DispatchSourceSignal` for `SIGTERM` and optionally `SIGINT`, with `Darwin.signal(signal, SIG_IGN)` before creating the dispatch source.
- Introduce an `AppCleanupCoordinator` that owns normal termination cleanup and is idempotent.
- Route `applicationShouldTerminate` through the same cleanup coordinator.
- Keep emergency cleanup intentionally small: restore native Command-Tab, mark termination, and drain captures only from a safe queue/main path.

Expected impact:

- Removes the highest-risk crash-path behavior.
- Makes normal quit, Activity Monitor termination, and CLI `kill -TERM` share one cleanup path.
- Reduces the chance of deadlocks and masked crash reports.

Risk:

- Native Command-Tab restoration must still happen for normal termination and SIGTERM.
- Screenshot drain behavior exists to avoid unwanted macOS permission prompts; it must be preserved for normal termination, but not attempted from a raw signal handler.

Validation strategy:

- Add unit tests for cleanup idempotency.
- Manually test Quit menu, Settings quit button, Activity Monitor quit/force quit, and `kill -TERM`.
- Verify `setNativeCommandTabEnabled(true)` is called once.
- Verify `SIGKILL` remains explicitly unsupported.
- Verify crash reports are not converted into clean `exit(0)` paths.

Migration guidance:

- First move `makeSureAllCapturesAreFinished` behind an idempotent coordinator without changing behavior.
- Then replace raw `SIGTERM` handler with `DispatchSourceSignal`.
- Remove `SIGTRAP` handling last, after confirming crash reporting still captures Swift traps.

### Phase 2: AX observer registration idempotency

Scope:

- Add explicit registration state to `Application`:
  - `private var didAttachAXRunLoopSource = false`
  - `private var subscribedAXNotifications = Set<String>()`
  - optional `private var axObserverCreationAttempted = false` if useful for logging
- Add equivalent per-window state in `Window`.
- Make `observeEventsIfEligible` call `ensureAXObjects`, `attachAXRunLoopSourceIfNeeded`, and `subscribeToAXNotificationsIfNeeded`.
- Log subscription attempts and outcomes in a structured way.
- Clean scheduler entries and possibly remove run-loop sources when windows/apps are removed, where the API ownership makes that practical.

Expected impact:

- Repeated KVO/window-init calls become harmless and auditable.
- Lower risk of duplicate notification subscriptions and repeated run-loop source attachment.
- Better diagnostics for apps that are slow, unresponsive, or AX-hostile.

Risk:

- Subscribing too late may miss windows created during launch.
- Over-aggressive “already subscribed” bookkeeping could incorrectly suppress retries after `.cannotComplete` or transient AX failures.

Validation strategy:

- Add tests around repeated `observeEventsIfEligible` calls using a small testable observer registrar wrapper.
- Preserve manual reconciliation via `Applications.manuallyUpdateWindows`.
- Manually test apps that restore windows on launch, apps with delayed launch completion, Electron apps, Finder, and apps known to be AX-noisy.

Migration guidance:

- Do not remove the manual window reconciliation path.
- Treat a notification as subscribed only after `AXObserverAddNotification` succeeds.
- Preserve retry/backoff behavior in `AXCallScheduler`.

### Phase 3: State isolation

Scope:

- Introduce a `SwitcherSessionState` as a main-thread-confined object first.
- Move session fields into it incrementally:
  - `isUsingSwitcher`
  - `activeShortcutIndex`
  - `forceDoNothingOnRelease`
  - first-summon flags
  - delayed display token/counter
  - search query and selection restore flags
  - selected and hovered window identifiers
- Keep static `App` methods as a compatibility facade during migration.
- Add `dispatchPrecondition(condition: .onQueue(.main))` or a local main-thread assertion around mutating methods until `@MainActor` is viable.

Expected impact:

- Makes switcher state ownership explicit.
- Reduces hidden dependencies between `App`, `Windows`, `TilesView`, `ATShortcut`, and trackpad events.
- Gives tests a real object to instantiate instead of mock global classes.

Risk:

- Shortcut release behavior is timing-sensitive, especially `focusOnRelease`, `searchOnRelease`, and transitions between multiple shortcuts.
- Delayed panel display can race with hide/focus events if the token migration is wrong.

Validation strategy:

- Extend `KeyboardEventsTests` around:
  - focus on release
  - search on release
  - switching from shortcut 0 to shortcut 1 while the UI is open
  - release suppression through `forceDoNothingOnRelease`
- Add tests for delayed display cancellation.
- Run real switching with key repeat, trackpad gesture, search mode, and cancel/focus flows.

Migration guidance:

- Start by wrapping existing static state, not by changing all call sites.
- Move fields one cluster at a time: shortcut/session flags first, then search query flags, then selection state.
- Keep all AppKit mutations on main.

### Phase 4: UI/domain decoupling

Scope:

- Extract pure policy types:
  - `WindowFilteringPolicy`
  - `WindowSortingPolicy`
  - `WindowSelectionPolicy`
  - `SearchSessionPolicy`
- Feed those policies with value snapshots rather than live AppKit objects where practical.
- Keep `TilesView`, `TilesPanel`, and `TileView` responsible for rendering and interaction forwarding.
- Introduce a presenter/coordinator that applies policy results to UI.

Expected impact:

- Selection and search behavior become testable without AppKit UI state.
- `Windows` can shrink toward window inventory/state rather than UI orchestration.
- UI changes become less likely to alter focus/selection semantics.

Risk:

- Filtering and sorting encode many product decisions around Spaces, screens, hidden/minimized/fullscreen windows, windowless apps, and exceptions.
- Search selection has subtle behavior around preserving/restoring selection.

Validation strategy:

- Add focused tests for:
  - active/non-active app filters
  - visible/non-visible Spaces filters
  - showing AltTab screen filter
  - hidden/minimized/windowless “show at end” buckets
  - recently focused/recently created/alphabetical/space ordering
  - search query changes and search clear restoration
  - focus changed while switcher is open

Migration guidance:

- Do not move rendering and policy in the same patch.
- First extract pure functions from existing `Windows` methods with identical inputs/outputs.
- Then introduce snapshots and tests.
- Only after tests are stable should `TilesView` calls move behind a presenter.

### Phase 5: Concurrency modernization and platform strategy

Scope:

- Replace deprecated `OSAtomic*` counters with either Swift Atomics `ManagedAtomic` or a tiny `NSLock`-protected counter.
- Add explicit main-thread or `@MainActor` boundaries for UI mutation paths once deployment/toolchain constraints allow it.
- Consider actor-backed services only for self-contained state that is not latency-critical on every key event.
- Keep AX scheduling and capture work on bounded queues until a measured actor migration proves equivalent latency.
- Define a deployment-target uplift plan before broad async/await adoption.

Expected impact:

- Reduces race risk and removes deprecated synchronization primitives.
- Makes UI mutation rules compiler-enforced over time.
- Keeps performance-sensitive switching paths predictable.

Risk:

- Broad actor migration is unrealistic while preserving a historical macOS 10.12 deployment target.
- Actors can introduce suspension points and ordering changes in latency-sensitive key/AX paths.

Validation strategy:

- Measure switcher show latency before/after.
- Stress test rapid switching, key repeat, trackpad gestures, and AX-heavy app launch/quit cycles.
- Monitor queue depth and thread counts with the existing debug instrumentation.

Migration guidance:

- Use main-thread confinement first.
- Use actors later for services with clear ownership and cancellation semantics.
- Do not migrate `AXCallScheduler` to actors until its throttling/backoff behavior is covered by tests.

### Permissions, AX events, and switching behavior guardrails

- Do not prompt for Accessibility permission from passive timers. Keep prompts user-initiated from the permissions UI.
- Preserve manual AX reconciliation even after observer idempotency is improved.
- Do not remove private API usage as part of architecture cleanup. The app intentionally uses private APIs for product capability; isolate those calls behind wrappers and document fallback behavior.
- Keep native Command-Tab restoration as a termination invariant.
- Keep thumbnail capture cancellation/draining behavior, but run it only from safe termination paths.

## 3. Code Comparison

### 1. Termination routing

Before:

```swift
[SIGTERM, SIGTRAP].forEach {
    signal($0) { s in
        emergencyExit("Exiting after receiving signal", s)
    }
}

fileprivate func emergencyExit(_ logs: Any?...) {
    setNativeCommandTabEnabled(true)
    print(logs)
    printStackTrace()
    makeSureAllCapturesAreFinished()
    exit(0)
}
```

After:

```swift
final class TerminationController {
    private var sources = [DispatchSourceSignal]()

    func start() {
        installSource(for: SIGTERM)
        installSource(for: SIGINT)
    }

    private func installSource(for signalNumber: Int32) {
        Darwin.signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            AppCleanupCoordinator.shared.beginTermination(reason: .signal(signalNumber))
        }
        source.resume()
        sources.append(source)
    }
}

@MainActor
final class AppCleanupCoordinator {
    static let shared = AppCleanupCoordinator()
    private var didBegin = false

    func beginTermination(reason: TerminationReason) {
        guard !didBegin else { return }
        didBegin = true
        App.isTerminating = true
        setNativeCommandTabEnabled(true)
        WindowCaptureDrain.shared.waitBrieflyThenTerminate()
    }
}
```

Why this is safer:

- The raw signal handler no longer performs Swift runtime work.
- Cleanup is idempotent.
- Normal termination and signal termination can share one path.
- Swift traps and Objective-C exceptions are left to crash reporting instead of being converted into clean exits.

### 2. AX observer registration idempotency

Before:

```swift
func observeEventsIfEligible() {
    if runningApplication.activationPolicy != .prohibited && !isReallyFinishedLaunching {
        if axUiElement == nil {
            axUiElement = AXUIElementCreateApplication(pid)
        }
        if axObserver == nil {
            AXObserverCreate(pid, AccessibilityEvents.axObserverCallback, &axObserver)
        }
        observeEvents()
    }
}

private func observeEvents() {
    guard let axObserver else { return }
    AXCallScheduler.shared.schedule(key: "sub-app-\(pid)", context: debugId, pid: pid) { ... }
    CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
}
```

After:

```swift
private var didAttachAXRunLoopSource = false
private var subscribedAXNotifications = Set<String>()

func observeEventsIfEligible() {
    guard runningApplication.activationPolicy != .prohibited, !isReallyFinishedLaunching else { return }
    ensureAXObjects()
    attachAXRunLoopSourceIfNeeded()
    subscribeToAXNotificationsIfNeeded()
}

private func ensureAXObjects() {
    if axUiElement == nil {
        axUiElement = AXUIElementCreateApplication(pid)
    }
    if axObserver == nil {
        AXObserverCreate(pid, AccessibilityEvents.axObserverCallback, &axObserver)
    }
}

private func attachAXRunLoopSourceIfNeeded() {
    guard !didAttachAXRunLoopSource, let axObserver else { return }
    CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
    didAttachAXRunLoopSource = true
}

private func subscribeToAXNotificationsIfNeeded() {
    for notification in Application.notifications where !subscribedAXNotifications.contains(notification) {
        scheduleSubscription(notification)
    }
}
```

Why this is safer:

- Repeated calls from init, KVO, and window creation become harmless.
- The code can distinguish object creation, source attachment, and notification subscription.
- Subscription success can be tracked per notification, preserving retries for transient AX failures.

### 3. Global switcher session state

Before:

```swift
class App: AppCenterApplication {
    static var appIsBeingUsed = false
    static var shortcutIndex = 0
    static var forceDoNothingOnRelease = false

    static func showUiOrCycleSelection(_ shortcutIndex: Int, _ forceDoNothingOnRelease_: Bool) {
        forceDoNothingOnRelease = forceDoNothingOnRelease_
        appIsBeingUsed = true
        UsageStats.recordTrigger(shortcutIndex)
        if isFirstSummon || shortcutIndex != App.shortcutIndex {
            App.shortcutIndex = shortcutIndex
            TilesView.startSearchSession(Preferences.shortcutStyle == .searchOnRelease)
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            Windows.setInitialSelectedAndHoveredWindowIndex()
            buildUiAndShowPanel()
        } else {
            cycleSelection(.leading)
            KeyRepeatTimer.startRepeatingKeyNextWindow()
        }
    }
}
```

After:

```swift
final class SwitcherSessionState {
    var isUsingSwitcher = false
    var activeShortcutIndex = 0
    var forceDoNothingOnRelease = false
    var isFirstSummon = true
    var isVeryFirstSummon = true
    var delayedDisplayGeneration = 0
}

@MainActor
final class AppCoordinator {
    private let session: SwitcherSessionState
    private let windowService: WindowSwitchingService
    private let ui: SwitcherUI

    func showOrCycle(shortcutIndex: Int, suppressReleaseFocus: Bool) {
        session.forceDoNothingOnRelease = suppressReleaseFocus
        session.isUsingSwitcher = true
        UsageStats.recordTrigger(shortcutIndex)
        if session.isFirstSummon || shortcutIndex != session.activeShortcutIndex {
            startSession(shortcutIndex)
        } else {
            cycleSelection(.leading)
        }
    }
}
```

Why this is safer:

- Session state has one owner.
- Static `App` methods can remain as a migration facade while logic moves into `AppCoordinator`.
- Tests can instantiate `SwitcherSessionState` without mocking global application classes.

### 4. Selection/search policy extraction

Before:

```swift
static func updateSelectedAndHoveredWindowIndex(_ newIndex: Int, _ fromMouse: Bool = false) {
    guard newIndex >= 0 && newIndex < list.count else { return }
    guard shouldDisplay(list[newIndex]) else { return }
    let oldIndex = selectedWindowIndex
    selectedWindowIndex = newIndex
    selectedWindowTarget = list[newIndex].id
    TilesView.highlight(oldIndex)
    previewSelectedWindowIfNeeded()
    let focusedView = TilesView.recycledViews[newIndex]
    TilesView.scrollView.contentView.scrollToVisible(focusedView.frame)
    voiceOverWindow(newIndex)
}
```

After:

```swift
struct WindowSelectionState {
    var selectedIndex: Int
    var selectedTarget: String?
    var hoveredIndex: Int?
    var lastActivity: WindowActivityType
}

struct WindowSelectionPolicy {
    func selecting(index: Int, fromMouse: Bool, windows: [WindowSnapshot], state: WindowSelectionState) -> WindowSelectionResult {
        guard windows.indices.contains(index), windows[index].isVisible else { return .unchanged(state) }
        var next = state
        next.selectedIndex = index
        next.selectedTarget = windows[index].id
        return .changed(next, effects: [.highlightPrevious, .highlightCurrent, .preview, .scrollToSelection, .voiceOver])
    }
}

@MainActor
final class TilesPresenter {
    func apply(_ result: WindowSelectionResult) {
        session.selection = result.state
        ui.apply(result.effects)
    }
}
```

Why this is safer:

- Selection decisions become pure and independently testable.
- AppKit work remains in a presenter/UI layer.
- Search/filtering changes can be validated with data snapshots instead of live `TilesView` state.

## Recommended implementation order

1. Add `AppCleanupCoordinator` and make normal termination idempotent.
2. Replace raw `SIGTERM` handling with `DispatchSourceSignal`; remove `SIGTRAP` recovery.
3. Add AX observer registration state and logging.
4. Add focused tests for repeated observer registration.
5. Introduce `SwitcherSessionState` as a wrapper around current static fields.
6. Move shortcut/session flags into `SwitcherSessionState`.
7. Extract `WindowSelectionPolicy` from `Windows` without changing behavior.
8. Extract filtering/sorting policies and build tests around preference combinations.
9. Replace deprecated atomics.
10. Plan deployment target uplift before broad actor/async migration.

## Suggested first patch

The best first patch is lifecycle-only:

- Add `TerminationController.swift`.
- Add `AppCleanupCoordinator.swift`.
- Move `makeSureAllCapturesAreFinished` behind the coordinator.
- Replace the raw `SIGTERM` handler.
- Stop intercepting `SIGTRAP`.
- Route `applicationShouldTerminate` through the coordinator.

That patch has the clearest risk reduction and the least entanglement with switching behavior.
