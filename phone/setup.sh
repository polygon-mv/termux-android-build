# Runs ON THE PHONE over ssh (piped by `tab setup`). Installs the build toolchain and writes
# ~/.tab/env (sourced by every tab command) and ~/.gradle/gradle.properties. Re-runnable.
set -euo pipefail
apt() { apt-get -yq -o Dpkg::Options::=--force-confnew "$@"; }

mkdir -p ~/.tab ~/.tab/dl ~/.gradle
jdk_pkgs=""; for v in $TAB_JDKS; do jdk_pkgs+=" openjdk-$v"; done
apt update
apt install $jdk_pkgs git cmake ninja aapt2 ccache rsync unzip wget which procps $TAB_PKGS

SDK=$HOME/android-sdk
JAVA_HOME=$PREFIX/lib/jvm/java-$TAB_JAVA_HOME_VERSION-openjdk
export JAVA_HOME

# --- Android SDK: Google's cmdline-tools are Java and run fine on arm64. The platform and
# build-tools packages are "linux" (x86_64) builds; the only native tool Gradle needs from them is
# aapt2, which is replaced by Termux's arm64 aapt2 below.
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -O ~/.tab/dl/clt.zip
  mkdir -p "$SDK/cmdline-tools" && unzip -qo ~/.tab/dl/clt.zip -d "$SDK/cmdline-tools"
  rm -rf "$SDK/cmdline-tools/latest" && mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
fi
yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
# shellcheck disable=SC2086
"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" $TAB_SDK_PACKAGES | grep -v '^\[' || true
for bt in "$SDK"/build-tools/*/; do ln -sf "$PREFIX/bin/aapt2" "$bt/aapt2"; done

# --- NDK: Google ships no arm64-host NDK. HomuHomu833/android-ndk-custom builds the same NDK
# releases for aarch64 hosts (static binaries, `aarch64-linux-android` = bionic). It goes in under
# the exact version the project asks for, so Gradle's ndkVersion check passes unchanged.
if [ -n "$TAB_NDK_VERSION" ] && [ ! -d "$SDK/ndk/$TAB_NDK_VERSION" ]; then
  [ -n "$TAB_NDK_RELEASE" ] || { echo "TAB_NDK_VERSION needs TAB_NDK_RELEASE (e.g. r27b)"; exit 1; }
  major=$(sed -E 's/^(r[0-9]+).*/\1/' <<<"$TAB_NDK_RELEASE")
  wget -q "https://github.com/HomuHomu833/android-ndk-custom/releases/download/$major/android-ndk-$TAB_NDK_RELEASE-aarch64-linux-android.tar.xz" -O ~/.tab/dl/ndk.tar.xz
  mkdir -p "$SDK/ndk" && tar -xJf ~/.tab/dl/ndk.tar.xz -C "$SDK/ndk"
  mv "$SDK/ndk/android-ndk-$TAB_NDK_RELEASE" "$SDK/ndk/$TAB_NDK_VERSION"
  rm ~/.tab/dl/ndk.tar.xz
  grep -q "Pkg.Revision = $TAB_NDK_VERSION" "$SDK/ndk/$TAB_NDK_VERSION/source.properties" ||
    echo "WARNING: $TAB_NDK_RELEASE's source.properties is not $TAB_NDK_VERSION; Gradle may reject it"
fi

# --- bun (optional): there is no bionic build, but the glibc one runs under Termux's glibc-runner.
if [ -n "$TAB_BUN_VERSION" ] && [ "$(grun ~/.tab/bun/bun --version 2>/dev/null)" != "$TAB_BUN_VERSION" ]; then
  apt install glibc-repo && apt update && apt install glibc-runner
  wget -q "https://github.com/oven-sh/bun/releases/download/bun-v$TAB_BUN_VERSION/bun-linux-aarch64.zip" -O ~/.tab/dl/bun.zip
  rm -rf ~/.tab/bun && unzip -qo ~/.tab/dl/bun.zip -d ~/.tab && mv ~/.tab/bun-linux-aarch64 ~/.tab/bun
  rm ~/.tab/dl/bun.zip
fi

jdk_paths=""; for v in $TAB_JDKS; do jdk_paths+="${jdk_paths:+,}$PREFIX/lib/jvm/java-$v-openjdk"; done
cmake_version=$(cmake --version | awk 'NR==1{print $3}')
cores=$(grep -c ^processor /proc/cpuinfo)

# Android denies apps /proc/stat, so Node's os.cpus() returns [] in Termux. Tools that size a
# pool with os.cpus().length then get 0 workers and stop silently (@expo/fingerprint's I/O
# limiter: the process exits 0 mid-run). Preloaded into every node via NODE_OPTIONS.
cat > ~/.tab/node-cpus.cjs <<'JS'
const os = require("os");
const real = os.cpus;
os.cpus = function cpus() {
  const list = real.call(os);
  if (list.length > 0) return list;
  const times = { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 };
  return Array.from({ length: os.availableParallelism() }, () => ({ model: "unknown", speed: 0, times }));
};
JS

cat > ~/.tab/env <<ENV
export ANDROID_HOME=$SDK ANDROID_SDK_ROOT=$SDK
export JAVA_HOME=$JAVA_HOME
export PATH=\$PATH:$SDK/cmdline-tools/latest/bin
export GRADLE_OPTS="-Dorg.gradle.native=false"
# sshd runs under run-as (see tab sshd). There, termux-exec would start programs through
# /system/bin/linker64, which cannot run the NDK's static clang ("unexpected e_type: 2").
export TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE=disable
# CMake 4 refuses projects declaring cmake_minimum_required < 3.5 unless told otherwise.
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export NODE_OPTIONS="--require $HOME/.tab/node-cpus.cjs"
ENV

cat > ~/.gradle/gradle.properties.tab <<PROPS
# Written by termux-android-build (phone/setup.sh). Phone-only; the project's own files are untouched.
org.gradle.jvmargs=-Xmx$TAB_GRADLE_HEAP -XX:MaxMetaspaceSize=768m -XX:+UseParallelGC
org.gradle.workers.max=${TAB_GRADLE_WORKERS:-$cores}
org.gradle.daemon=false
org.gradle.caching=true
# Gradle's native-platform JNI libraries are glibc builds and do not load on bionic.
org.gradle.native=false
org.gradle.vfs.watch=false
kotlin.daemon.jvmargs=-Xmx1536m
# AGP downloads an x86_64 aapt2 from Maven; use Termux's arm64 one.
android.aapt2FromMavenOverride=$PREFIX/bin/aapt2
# Termux's cmake, pointed to by local.properties cmake.dir (tab build writes it).
android.cmakeVersion=$cmake_version
# Gradle cannot auto-detect or download JDKs here (foojay has no Android); list Termux's.
org.gradle.java.installations.paths=$jdk_paths
org.gradle.java.installations.auto-download=false
$TAB_GRADLE_PROPS
PROPS
mv ~/.gradle/gradle.properties.tab ~/.gradle/gradle.properties

echo "setup done: $(java -version 2>&1 | head -1), cmake $cmake_version, $cores cores"
ls "$SDK/ndk" 2>/dev/null | sed 's/^/ndk: /'
