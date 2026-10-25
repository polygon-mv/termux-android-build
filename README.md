# termux-android-build

Build Android apps **on an Android phone**: Gradle, the Android SDK, the NDK, CMake and clang all
run inside [Termux](https://termux.dev) on the phone, while your computer only sends the source
over USB and reads the log. Any Gradle project works; React Native / Expo needs a few extra
settings (see [React Native / Expo](#react-native--expo)).

Useful when the computer is the bottleneck: an 8 GB laptop that falls over under Gradle + Metro,
or a CI runner you don't have. A recent flagship phone has 8 cores and 12 GB of RAM, which is more
than many build machines.

```
computer                             phone (Termux, arm64)
────────                             ─────────────────────
tab sync  ── git archive | ssh ──▶   ~/src/<repo>  (local git repo, deps + build outputs kept)
tab build ── ssh ───────────────▶    your build command, in the background → ~/.tab/build.log
tab watch ◀─ ssh ───────────────     task count, failures, low memory, exit
tab apk   ◀─ ssh ───────────────     newest APK  (or install it on the phone directly)
```

## Requirements

- An arm64 Android phone with USB debugging on, and `adb` on the computer. No root needed.
- A computer with `bash`, `git`, `ssh`, `curl`. Tested from macOS.
- Phone storage: about 10 GB for the toolchain and caches, plus your project.

## Quick start

```bash
git clone https://github.com/polygon-mv/termux-android-build
cd your-android-project
cat > .tab.env <<'EOF'
TAB_SDK_PACKAGES="platforms;android-36 build-tools;36.0.0"
TAB_NDK_VERSION=27.1.12297006   # only if the project has native code: its ndkVersion
TAB_NDK_RELEASE=r27b            # the NDK release with that version
TAB_BUILD_CMD='./gradlew assembleDebug'
EOF
../termux-android-build/tab setup   # once: Termux, sshd, JDK, SDK, NDK  (~10 min)
../termux-android-build/tab sync    # send HEAD to the phone
../termux-android-build/tab build   # start the build
../termux-android-build/tab watch   # until it exits
../termux-android-build/tab apk     # copy the APK back (or adb install it from there)
```

| command          | what it does                                                                     |
| ---------------- | -------------------------------------------------------------------------------- |
| `tab setup`      | installs Termux (GitHub build, checksum-verified), sshd, toolchain; re-runnable  |
| `tab sshd`       | (re)starts sshd the safe way (see below) and forwards the port; after a reboot   |
| `tab sync [rev]` | `git archive` of a rev → phone, one local commit per sync, then `TAB_POST_SYNC`  |
| `tab build`      | runs `TAB_BUILD_CMD` in `TAB_BUILD_DIR`, detached; survives a dropped USB link   |
| `tab watch`      | one line per 100 Gradle tasks + failures + low memory; exits with the build      |
| `tab log [n]`    | tail of the build log                                                            |
| `tab apk`        | copies the newest `TAB_APK_GLOB` match to the current directory, with sha256     |
| `tab ssh [cmd]`  | shell / command on the phone with the build environment loaded                   |

## Configuration

Environment variables, or a file sourced from `TAB_CONFIG` (default `./.tab.env`).

| variable                | default                          | meaning                                                  |
| ----------------------- | -------------------------------- | -------------------------------------------------------- |
| `TAB_SERIAL`            | the only device                  | `adb` serial                                             |
| `TAB_KEY`               | `~/.ssh/termux_build`            | ssh key (created by setup)                               |
| `TAB_PORT`              | `8022`                           | local port forwarded to the phone's sshd                 |
| `TAB_TERMUX_VERSION`    | `v0.118.3`                       | termux-app GitHub release                                |
| `TAB_JDKS`              | `17 21`                          | Termux OpenJDKs to install (Gradle toolchains)           |
| `TAB_JAVA_HOME_VERSION` | `21`                             | the one Gradle itself runs on                            |
| `TAB_SDK_PACKAGES`      | `platforms;android-36 build-tools;36.0.0` | `sdkmanager` packages                           |
| `TAB_NDK_VERSION`       | (none)                           | NDK version the project asks for (`ndkVersion`)          |
| `TAB_NDK_RELEASE`       | (none)                           | matching NDK release name, e.g. `r27b`                   |
| `TAB_PKGS`              | (none)                           | extra Termux packages, e.g. `nodejs-lts`                 |
| `TAB_BUN_VERSION`       | (none)                           | install bun (glibc build, run as `grun ~/.tab/bun/bun`)  |
| `TAB_GRADLE_HEAP`       | `3g`                             | Gradle daemon heap                                       |
| `TAB_GRADLE_WORKERS`    | all cores                        | `org.gradle.workers.max`                                 |
| `TAB_GRADLE_PROPS`      | (none)                           | extra lines for the phone's `~/.gradle/gradle.properties` |
| `TAB_REPO`              | git toplevel of the cwd          | the project on the computer                              |
| `TAB_PHONE_DIR`         | `src/<repo name>`                | where it lives on the phone (relative to Termux home)    |
| `TAB_POST_SYNC`         | (none)                           | phone-side shell after each sync (install deps, etc.)    |
| `TAB_BUILD_DIR`         | `.`                              | directory the build command runs in                      |
| `TAB_BUILD_CMD`         | `./gradlew assembleDebug`        | the build                                                |
| `TAB_APK_GLOB`          | `**/build/outputs/**/*.apk`      | what `tab apk` picks up                                  |

Nothing is written into your project. Phone-only Gradle settings go into the phone's
`~/.gradle/gradle.properties`, and `local.properties` (`sdk.dir`, `cmake.dir`) is generated
beside each `gradlew` at build time.

## What it works around

Each of these failed a real build before it was handled here.

1. **Android's phantom process killer.** Android 12+ caps the processes an app may spawn at 32
   (across all apps) and, past that, kills *all* of them: logcat says `Trimming phantom
   processes`. A Gradle build running ninja with a clang per core passes 32 within seconds, and the
   kill takes sshd with it. Keeping Termux in the foreground does not help; it is a count limit.
   **Fix without touching settings:** the GitHub build of Termux is debuggable, so
   `adb shell run-as com.termux …` can start sshd. That sshd is a child of `adbd`, not of the
   Termux app, so nothing started over ssh is counted. It also runs in the root cpuset: all cores
   even when Termux is in the background (a backgrounded app gets 3 on a Galaxy S23).
   (The alternative, `settings put global settings_enable_monitor_phantom_procs false`, changes a
   system setting; this tool does not need it.)
2. **No arm64-host NDK from Google.** [HomuHomu833/android-ndk-custom](https://github.com/HomuHomu833/android-ndk-custom)
   builds the NDK releases for aarch64 hosts. Setup installs it under the exact version number
   the project requests, so `ndkVersion` checks pass unchanged.
3. **Static clang vs termux-exec.** In the `run-as` context, termux-exec starts programs through
   `/system/bin/linker64`, which cannot load a static executable: `clang-18 has unexpected
   e_type: 2`. The build env sets `TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE=disable`.
4. **x86_64 aapt2.** AGP downloads aapt2 from Maven (x86_64 Linux). `android.aapt2FromMavenOverride`
   points at Termux's arm64 `aapt2`, and the SDK build-tools copies are symlinked to it.
5. **Gradle's native integration** is glibc-only: `org.gradle.native=false`, no file watching.
6. **JDK toolchains.** Plugins that ask for a Java 17 toolchain fail (foojay can't provision on
   Android). Setup installs the JDKs in `TAB_JDKS` and lists them in
   `org.gradle.java.installations.paths`.
7. **CMake 4.** Termux ships CMake 4, which rejects `cmake_minimum_required(VERSION <3.5)` unless
   `CMAKE_POLICY_VERSION_MINIMUM=3.5` is set (it is). Modules that pin
   `externalNativeBuild.cmake.version` to a 3.x the SDK would provide need that version changed
   or overridden; Expo projects get it for free via `android.cmakeVersion`.
8. **`os.cpus()` is empty.** Android denies apps `/proc/stat`, so Node reports zero CPUs. Tools
   that size a pool with `os.cpus().length` get zero workers and stall; `@expo/fingerprint` (and
   so `expo-updates` and rn-build-cache) exits 0 halfway with no output. Every `node` on the phone
   preloads `~/.tab/node-cpus.cjs` (via `NODE_OPTIONS`), which fills `os.cpus()` from
   `os.availableParallelism()` when it comes back empty.
9. **Typing into Termux** with `adb shell input text` garbles input, so setup never types:
   everything goes through `run-as` or ssh.

Builds are incremental across syncs: `node_modules`, `.gradle`, `.cxx`, `build/` and
`local.properties` survive `tab sync` (tracked files with those names still update). Setup turns
on Gradle's build cache and installs `ccache`, which CMake projects that look for it (React
Native's do) use automatically.

## React Native / Expo

- **Node** comes from Termux (`TAB_PKGS="nodejs-lts"`); Gradle shells out to it for autolinking
  and codegen.
- **bun** has no bionic build; its glibc build runs under Termux's `glibc-runner`
  (`TAB_BUN_VERSION`). Lifecycle scripts can't run there (`/usr/bin/env` doesn't exist in the
  glibc environment), so install with `--ignore-scripts` and run what your postinstall needs with
  node. npm / yarn / pnpm run natively under Termux's node.
- **[rn-build-cache](https://github.com/polygon-mv/rn-build-cache)** works unchanged as the build
  command and gives the same fingerprint-keyed caching as on a computer: no native change, no
  build. `tab sync` commits each rev locally because rn-build-cache fingerprints the committed tree
  and restores `expo prebuild`'s edits with git. Its remote cache needs an authed `gh` on the
  phone; without one it uses the local cache only.
- **Metro** stays on the computer: `adb reverse tcp:8081 tcp:8081`.

Example `.tab.env` for an Expo monorepo app with rn-build-cache:

```bash
TAB_SDK_PACKAGES="platforms;android-36 build-tools;36.0.0"
TAB_NDK_VERSION=27.1.12297006
TAB_NDK_RELEASE=r27b
TAB_PKGS="nodejs-lts"
TAB_BUN_VERSION=1.4.3
TAB_POST_SYNC='grun ~/.tab/bun/bun install --frozen-lockfile --ignore-scripts'
TAB_BUILD_DIR=apps/mobile
TAB_BUILD_CMD='node ../../node_modules/@polygon-mv/rn-build-cache/bin/rn-build-cache.js --variant dev'
TAB_APK_GLOB='android/app/build/outputs/rn-build-cache/*.apk'
```

## Caveats

- The phone gets hot; it throttles itself and the build slows down. Keep it on a charger and out
  of a case.
- Termux's packages move: `apt upgrade` can bring a new CMake or JDK. Re-run `tab setup` to
  rewrite the Gradle properties after one.
- APKs built this way use a community NDK build. Fine for development builds; for releases, use
  your normal pipeline.

## License

MIT
