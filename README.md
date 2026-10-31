# AltTab (personal fork)

Brings the power of Windows Alt-Tab to macOS.

Fork of [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos), based on upstream **v11.10.1**.

For personal use, not distributed.

## Differences from upstream

Every fork edit to upstream files is explained by a `fork:` comment, next to it or at the top of the same function. To list them, run:

```sh
grep -rn "fork:" src config scripts ai .gitignore
```

| Area | Upstream | This fork |
|---|---|---|
| Pro features: shortcuts 2–9, search, App Icons and Titles styles, Auto size, "Search" release action | Paid after a 14-day trial | Always unlocked |
| Pro UI: trial prompts, "Get Pro", "My Account", Pro badges, Settings upgrade button | Shown | Hidden |
| Network: update checks, license server, feedback form (alt-tab.app) | On | Off. The updater never starts, the license client is offline, and "Check for updates", "About" and "Send feedback" are removed from the menu |
| Languages | 21 | English only, set in `config/base.xcconfig` |
| Screen Recording | Asked during setup | Skipped by default, with no menu-bar reminder while skipped |
| "Hide app badges", "Align windows" settings | Removed | Restored from v10 |
| Space number labels | Hidden by default | Shown by default, as in v10 |
| Lock search | Removed | Not restored, see below |
| Release signing | Developer ID, notarized | Local self-signed certificate, not notarized, set in `config/release.xcconfig` |

### Lock search (removed upstream, not restored)

v10 had a third search state. While searching, **Space** locked the results: typing stopped, and the single-key shortcuts acted on the filtered windows. Those are `W` close, `M` minimize, `F` fullscreen, `Q` quit, `H` hide. Space again resumed typing, so a search query could not contain a space.

Upstream removed it in commit `47fd455a`. Now, while searching:

- Letters and Space always type into the search field.
- Esc, Return and the arrow keys work as before.
- To use a single-key shortcut, also hold the switcher's hold key (`⌥` by default). For example, `⌥W` closes the selected window.

It is not restored because doing so would change search code that upstream keeps editing, causing conflicts on every rebase.

## Prerequisites

Do these once per Mac, in order.

1. macOS 12 or later, with the full Xcode app installed from the App Store or [developer.apple.com](https://developer.apple.com/xcode/). The Command Line Tools alone are not enough. This fork is built with Xcode 27.2. Launch Xcode once and let it install its additional components.

2. Point the Command Line Tools at Xcode. Check the active developer directory:

```sh
xcode-select -p
```

It must print `/Applications/Xcode.app/Contents/Developer`. If it prints `/Library/Developer/CommandLineTools`, or fails, switch it to Xcode:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If Xcode is not in `/Applications`, or has a different name such as `Xcode-beta.app`, use its actual path.

3. Accept the Xcode license and finish the first-launch setup:

```sh
sudo xcodebuild -license accept
```

```sh
sudo xcodebuild -runFirstLaunch
```

If `xcodebuild` says it *requires Xcode, but active developer directory … is a command line tools instance*, step 2 was skipped. Do step 2, then repeat this step. To check that it worked, run `xcodebuild -version`. It should print the Xcode version with no license prompt.

4. Python 3 on `PATH`. The build uses it to check the illustrations. Check it with:

```sh
python3 --version
```

## Building from source

Run every command from the repository root.

1. Clean up generated and downloaded files. This deletes `DerivedData`, which otherwise keeps stale resources across branch switches.

```sh
scripts/cleanup_generated_and_downloaded.sh
```

2. Create the local code-signing certificate. This is needed once every 10 years, or whenever `security find-identity -v -p codesigning` shows no valid `Local Self-Signed` identity. macOS asks for your password.

```sh
scripts/codesign/setup_local.sh
```

```sh
security find-identity -v -p codesigning | grep "Local Self-Signed"
```

Running step 1 afterwards removes the `codesign.*` files this step leaves in the repository root.

3. Build the Release version:

```sh
python3 scripts/assets/compile_illustrations.py --check
xcodebuild -project alt-tab-macos.xcodeproj -scheme Release -configuration Release -derivedDataPath DerivedData
```

Use Release day to day. `bash ai/build.sh` builds Debug, which is for development only: it opens a QA panel at every launch, and its test scenarios can fake an expired trial and show "Get Pro" prompts until the app quits.

4. Quit any running AltTab, then launch the build:

```sh
pkill -x AltTab
open DerivedData/Build/Products/Release/AltTab.app
```

The official AltTab uses the same bundle ID, and therefore the same settings, so quit it too.

5. Run the unit tests:

```sh
bash ai/test.sh
```

### Permissions

A new signing certificate changes the app's signature, so macOS may keep a stale permission entry. Reset it, then relaunch and grant the permission when asked:

```sh
pkill -x AltTab
tccutil reset Accessibility com.lwouis.alt-tab-macos
tccutil reset ScreenCapture com.lwouis.alt-tab-macos # only if you use Screen Recording
open DerivedData/Build/Products/Release/AltTab.app
```

### Debug build and QA panel

The Debug build is for development. Build it, then quit the Release app and launch Debug in its place:

```sh
bash ai/build.sh
pkill -x AltTab
open DerivedData/Build/Products/Debug/AltTab.app
```

Debug adds a QA panel, with test controls for the trial journey, Pro prompts, the clock, and debug tools. Release compiles all of it out.

- It opens at every launch. After closing it, middle-click the AltTab menu-bar icon to show or hide it again.
- It does not open when the app is launched with `--qa-no-menu` or `--qa-lifecycle-session=<UUID>`.
- Debug and Release share the bundle ID, so they share settings and permissions. Run only one at a time.

The trial scenarios fake a trial day in memory. That overrides the fork's Pro unlock, so trial prompts and "Get Pro" windows come back, with made-up usage numbers such as "Extra shortcut uses during your trial: 12".

- Quitting the app clears the faked trial. "Reset trial state and clock" in the panel does not: it only resets the prompt flags and the clock.
- The scenarios also write `proTransition.*` flags to the `com.lwouis.alt-tab-macos.license` defaults. They are harmless, since the fork always reports Pro, and the panel's reset clears them.

To go back to the Release app:

```sh
pkill -x AltTab
open DerivedData/Build/Products/Release/AltTab.app
```

### Settings backup

```sh
defaults export com.lwouis.alt-tab-macos ~/alttab-prefs-backup.plist # back up
defaults import com.lwouis.alt-tab-macos ~/alttab-prefs-backup.plist # restore; quit AltTab first
```

## Updating from upstream

1. Fetch the latest upstream release:

```sh
git remote add upstream https://github.com/lwouis/alt-tab-macos.git # once per clone
git fetch upstream --tags
git tag --sort=-v:refname | head -3
```

2. Rebase the fork commits onto the new tag, for example `v11.11.0`:

```sh
git rebase --onto v11.11.0 v11.10.1
```

On a conflict, keep upstream's code and re-apply the `fork:` edit.

3. Set `CURRENT_PROJECT_VERSION` in `config/base.xcconfig` to the new tag, and update the version at the top of this README.

4. Build, run the tests, and launch the app, using steps 3–5 above. A passing build and test run is not enough: always launch.

## Licence

GPL-3.0, see [LICENCE.md](LICENCE.md).
