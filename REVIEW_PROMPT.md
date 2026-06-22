You are an expert macOS App Architect and Principal Engineer specializing in AppKit-first system utilities, private/public macOS APIs, and modern Swift concurrency migration.

Conduct a rigorous architectural review and refactoring proposal for this repository: AltTab (macOS application switcher).

### Project Context (filled for this repo)

- Purpose/Function: A menu-bar utility that provides advanced Alt-Tab style window/app switching on macOS, including thumbnails, search, multi-display/spaces behavior, and keyboard/trackpad navigation.
- Target macOS Version: Historically broad support (deployment target 10.12), with modern APIs conditionally used on newer systems.
- Current Stack: Pure AppKit + NSApplicationDelegate lifecycle, CocoaPods dependencies, mixed C/ObjC/Swift interop, private macOS APIs (SkyLight), extensive AX API integration.
- Current Architecture: Large static/global orchestration layer (`App`, `Windows`, `Applications`, `TilesView`), event-driven background threads/operation queues, tight coupling between state, business logic, and UI rendering.

### Required Evaluation Focus

1. macOS-specific best practices
   - App lifecycle correctness, shutdown/termination safety, and crash handling safety.
   - Efficiency for CPU/memory/battery under high-frequency AX/keyboard/window events.
   - Windowing/menu-bar behavior and non-activating panel correctness.
   - Security and distribution implications: unsandboxed mode, hardened runtime, private APIs.

2. Architecture and state management
   - Decoupling domain logic from AppKit view/controller code.
   - Scalability of event pipelines and global mutable state.
   - Testability impact of static singletons and side-effect-heavy methods.

3. Swift modernity
   - Opportunities to introduce actors, @MainActor boundaries, structured concurrency, and cancellation.
   - Practical migration strategy that respects current deployment constraints.

4. Maintainability and technical debt
   - Code smells (global state, hidden invariants, repeated observer registration risks, brittle shutdown paths).
   - Protocol-oriented seams for dependency inversion and unit testing.

### Output Requirements

Provide the review in three sections:

1. Architectural Critique
   - What is working well.
   - Highest-risk architectural issues, ranked by severity.
   - Concrete references to the current code paths involved.

2. Actionable Refactoring Plan
   - A phased plan with explicit implementation order.
   - For each phase: scope, expected impact, risk, and validation strategy.
   - Include migration guidance for not breaking existing behavior around permissions, AX events, and window switching.

3. Code Comparison (critical areas only)
   - Show "Before" and "After" code for the most important refactors.
   - Explain why each change is safer, more testable, or more maintainable.
   - Favor incremental refactors over unrealistic rewrites.

### Mandatory Critical Topics to Address

- Unsafe signal/crash handling in process entry path and termination behavior.
- Global mutable state concentration across `App`, `Windows`, and `TilesView`.
- Observer/run-loop registration idempotency for AX subscriptions.
- Concurrency safety of shared mutable state and deprecated atomics usage.
- Separation of UI rendering from window-selection/search domain logic.

### Suggested Refactor Direction (to evaluate and refine)

Phase 1: Safety and lifecycle hardening

- Introduce a termination coordinator and safe signal routing.
- Make observer registration idempotent and auditable.
- Add regression tests for lifecycle edge cases.

Phase 2: State isolation

- Introduce an explicit app session state store (single source of truth).
- Move shortcut/session/window selection state out of static globals.

Phase 3: UI/domain decoupling

- Extract window selection/search policy into a domain service.
- Keep AppKit classes focused on rendering and user interaction forwarding.

Phase 4: Concurrency modernization

- Add explicit @MainActor boundaries for UI mutation paths.
- Incrementally migrate high-contention shared state to actor-backed services.
- Replace deprecated atomics with modern synchronization.

Phase 5: Platform strategy

- Provide a realistic plan for deployment target uplift and async/await adoption.

### Example Before/After Snippets to Include in the Review

1. Global static state orchestration

Before:

```swift
class App: AppCenterApplication {
	static var appIsBeingUsed = false
	static var shortcutIndex = 0
	static func showUiOrCycleSelection(_ shortcutIndex: Int, _ forceDoNothingOnRelease_: Bool) {
		// mutates global state and drives UI directly
	}
}
```

After (directional):

```swift
actor AppSessionStore {
	var isUsingSwitcher = false
	var activeShortcutIndex = 0
}

@MainActor
final class AppCoordinator {
	private let session: AppSessionStore
	func handleShowSwitcher(shortcutIndex: Int) async {
		await session.activeShortcutIndex = shortcutIndex
		// call domain services, then render via UI surface
	}
}
```

2. AX observer registration idempotency

Before:

```swift
func observeEventsIfEligible() {
	if axObserver == nil { AXObserverCreate(pid, AccessibilityEvents.axObserverCallback, &axObserver) }
	observeEvents()
}
```

After (directional):

```swift
private var didAttachAXRunLoopSource = false
private var didSubscribeAXNotifications = false

func observeEventsIfEligible() {
	ensureAXObjects()
	guard !didSubscribeAXNotifications else { return }
	subscribeToAXNotifications()
	didSubscribeAXNotifications = true
	attachAXRunLoopSourceIfNeeded()
}
```

3. Raw signal handler with non-signal-safe work

Before:

```swift
signal(SIGTERM) { _ in
	emergencyExit("Exiting after signal")
}
```

After (directional):

```swift
final class TerminationController {
	func start() {
		Darwin.signal(SIGTERM, SIG_IGN)
		let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
		source.setEventHandler { AppCleanupCoordinator.shared.beginTerminationFlow() }
		source.resume()
	}
}
```

### Constraints

- Keep all suggestions compatible with AppKit (no SwiftUI rewrite).
- Preserve behavior and performance characteristics for real-time switching.
- Respect that private APIs may be intentionally used for product capability.
- Prefer incremental, testable steps that can be shipped safely.

The code under review is this current project.
