# macOS development

- Do not use Xcode UI directly for development tasks; use repository scripts/CLI workflows for build and test.
- Use pure Swift 5.8 code to make the app. No interface builder. No SwiftUI.
- Aim for compact code. Within methods, don't have groups of statements separated with newlines. No inline comments for simple code. Instead, split statements into sub-methods.
- Use guard clauses as much as possible to separate the happy-path under them
- Organize source files into folders. Folders should group files that change together, at the same pace (e.g. one feature)
- Favor low latency and responsiveness. Reuse objects, avoid wasting memory or I/O.

# Workflow

- Run `scripts/build_app_debug.sh` script, to confirm compilation works after you're done with implementing a change
- Run the built app after each successful build with command `open DerivedData/Build/Products/Debug/AltTab.app`

# License / Keychain invariant

- The app's Developer ID, TeamID, and bundle ID must remain stable across builds. Keychain items are tied to the code signature; changing any of these orphans every user's stored license key and forces mass re-activation. If a rotation is unavoidable, plan a migration first (e.g., a backup-restore handler, or `kSecAttrAccessGroup` with a stable group identifier).
- Do not introduce legacy `SecKeychain*` API or `kSecAccessControl` (biometric/PIN gating) into license code — both can trigger Keychain password prompts, which is bad UX for license activation.
