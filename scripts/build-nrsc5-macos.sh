#!/usr/bin/env bash
#
# Build libnrsc5.dylib (the macOS counterpart of bin/libnrsc5.dll /
# bin/libnrsc5.so) from the pinned upstream nrsc5 tag, with all native
# dependencies statically embedded, and stage it at bin/libnrsc5.dylib
# for the Rust link step.
#
# This is scripts/build-nrsc5-linux.sh ported to macOS. Same shape:
#   USE_STATIC=ON          -> libusb / librtlsdr / FFTW / FAAD2 are
#                             built from the bundled submodules and
#                             linked *into* libnrsc5.dylib, so the only
#                             runtime deps are macOS system libraries
#                             and frameworks.
#   USE_SYSTEM_*=OFF       -> don't pick up Homebrew/MacPorts copies.
#   BUILD_CLI=OFF          -> we only need the library.
#
# macOS deltas from the Linux script, in order of importance:
#
#   1. Apple frameworks on the shared link. The statically-embedded
#      libusb's darwin backend calls IOKit, CoreFoundation, Security
#      and Objective-C runtime symbols. On Linux/Windows those deps
#      don't exist; here the final dylib link fails with undefined
#      _SecTaskCreateFromSelf / _kCFAllocatorDefault / IOKit symbols
#      unless we pass:
#        -framework IOKit -framework CoreFoundation -framework Security -lobjc
#
#   2. install_name_tool instead of patchelf. There is no SONAME on
#      Mach-O; the equivalent knob is the dylib's install name (id),
#      which consumers record at link time. We set it to the absolute
#      path of the staged bin/libnrsc5.dylib so `cargo build` /
#      `cargo run` from this repo resolve it with no rpath and no
#      DYLD_LIBRARY_PATH. (A distributable .app would instead want
#      @rpath/libnrsc5.dylib plus an @loader_path rpath — deferred
#      until there is macOS packaging.)
#
#   3. CMAKE_POLICY_VERSION_MINIMUM=3.5 exported for CMake >= 4, which
#      refuses the older cmake_minimum_required in some of the bundled
#      sub-builds. The env var (unlike the -D flag) also reaches the
#      ExternalProject sub-configures.
#
#   4. The Linux script's -fPIC injection seds are dropped: every
#      macOS object is position-independent already.
#
# The two upstream source patches are shared with the Linux script and
# applied here with sed -i.bak so the script runs on both BSD sed
# (stock macOS) and GNU sed (Homebrew gnubin).
#
# Output: bin/libnrsc5.dylib (single self-contained dylib). The
# matching upstream header is synced to res/nrsc5.h, identical to the
# Windows and Linux builds.
#
# Usage from the repo root (tested on macOS 26 / Intel; the recipe is
# expected to carry to Apple Silicon with USE_SSE=OFF):
#
#   bash scripts/build-nrsc5-macos.sh
#
# Optional environment overrides:
#   NRSC5_TAG=v3.2.0   # which upstream tag to build
#   NRSC5_JOBS=8       # make -j N (default: hw.ncpu)
#   NRSC5_USE_SSE=ON   # OFF on Apple Silicon

set -euo pipefail

TAG="${NRSC5_TAG:-v3.2.0}"
JOBS="${NRSC5_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
USE_SSE="${NRSC5_USE_SSE:-ON}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
BUILD_ROOT="${TMPDIR:-/tmp}/nrsc5-macos-build"
SRC_DIR="$BUILD_ROOT/nrsc5-$TAG"

# CMake >= 4 refuses pre-3.5 cmake_minimum_required in some bundled
# sub-builds; the env var reaches ExternalProject sub-configures too.
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

echo "==> Building libnrsc5.dylib from nrsc5 $TAG (jobs=$JOBS, SSE=$USE_SSE)"

# --- 0. build prerequisites -------------------------------------------
# cc comes from the Xcode Command Line Tools; autoconf/automake/libtool
# are needed by the bundled FFTW / libusb / FAAD2 autotools sub-builds.
missing=()
for tool in git cmake make cc autoconf automake glibtool install_name_tool; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# Homebrew installs GNU libtool as glibtool; MacPorts and manual
# installs may provide plain libtool. Accept either.
if [[ " ${missing[*]-} " == *" glibtool "* ]] && command -v libtool >/dev/null 2>&1; then
  missing=("${missing[@]/glibtool}")
fi
missing=($(printf '%s\n' "${missing[@]-}" | grep -v '^$' || true))
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing build tools: ${missing[*]}" >&2
  echo "Install them first, e.g.:" >&2
  echo "  xcode-select --install          # git, make, cc, install_name_tool" >&2
  echo "  brew install autoconf automake libtool   # or MacPorts equivalents" >&2
  echo "  pip3 install cmake              # prebuilt wheel; avoids a source" >&2
  echo "                                  # build on brew-bottle-less hosts" >&2
  exit 1
fi

# --- 1. clone the pinned tag ------------------------------------------
rm -rf "$SRC_DIR"
mkdir -p "$BUILD_ROOT"
git clone --depth 1 --branch "$TAG" --recursive https://github.com/theori-io/nrsc5.git "$SRC_DIR"
cd "$SRC_DIR"
echo "==> ref: $(git log -1 --format='%H %s')"

# --- 1a. shared upstream patches (same as the Linux script) ------------
# nrsc5's CMakeLists hardcodes the *Windows* static-library filename for
# rtl-sdr (librtlsdr_static.a). The rtl-sdr static archive installs as
# librtlsdr.a on macOS, same as Linux.
if grep -q 'librtlsdr_static\.a' CMakeLists.txt; then
  sed -i.bak 's#/lib/librtlsdr_static\.a#/lib/librtlsdr.a#' CMakeLists.txt
  echo "==> patched CMakeLists: librtlsdr_static.a -> librtlsdr.a (macOS)"
fi

# nrsc5's USE_STATIC mode appends a bare "-static" to the shared
# libnrsc5 link. ld64 rejects -static for dylibs just as GNU ld does
# for shared objects. The dependencies stay statically linked (that is
# USE_STATIC's job); only the flag on the shared link must go.
if grep -q 'set (STATIC_LINKER_FLAGS -static)' src/CMakeLists.txt; then
  sed -i.bak 's/set (STATIC_LINKER_FLAGS -static)/set (STATIC_LINKER_FLAGS )/' src/CMakeLists.txt
  echo "==> patched src/CMakeLists: dropped -static from shared link"
fi
rm -f CMakeLists.txt.bak src/CMakeLists.txt.bak

# --- 2. configure + build ---------------------------------------------
mkdir -p build
cd build
cmake \
  -D CMAKE_BUILD_TYPE=Release \
  -D BUILD_SHARED_LIBS=ON \
  -D BUILD_CLI=OFF \
  -D BUILD_DOC=OFF \
  -D USE_STATIC=ON \
  -D USE_FAAD2=ON \
  -D USE_SYSTEM_LIBUSB=OFF \
  -D USE_SYSTEM_RTLSDR=OFF \
  -D USE_SYSTEM_FFTW=OFF \
  -D USE_SSE="$USE_SSE" \
  -D CMAKE_POSITION_INDEPENDENT_CODE=ON \
  -D CMAKE_SHARED_LINKER_FLAGS="-framework IOKit -framework CoreFoundation -framework Security -lobjc" \
  ..
make "-j$JOBS" nrsc5

# --- 3. locate the produced dylib --------------------------------------
BUILT_DYLIB="$(find "$SRC_DIR/build" -name 'libnrsc5*.dylib' -type f -print | head -n 1)"
if [[ -z "$BUILT_DYLIB" || ! -f "$BUILT_DYLIB" ]]; then
  echo "ERROR: build did not produce a libnrsc5*.dylib file" >&2
  find "$SRC_DIR/build" -name 'libnrsc5*' -print >&2 || true
  exit 1
fi
echo "==> built: $BUILT_DYLIB"

# --- 4. stage as bin/libnrsc5.dylib with an absolute install name ------
# The absolute id means the Rust binary records a path that resolves
# with no rpath and no DYLD_LIBRARY_PATH for dev builds from this repo.
mkdir -p "$BIN_DIR"
STAGED="$BIN_DIR/libnrsc5.dylib"
if [[ -f "$STAGED" ]]; then
  cp -f "$STAGED" "$STAGED.bak-$(date +%Y%m%d-%H%M%S)"
fi
cp -f "$BUILT_DYLIB" "$STAGED"
chmod 0755 "$STAGED"
install_name_tool -id "$STAGED" "$STAGED"
echo "==> staged: $STAGED"
echo "    id: $(otool -D "$STAGED" | tail -1)"
otool -L "$STAGED" | sed -n '2,10p'

# --- 5. sync the matching header ---------------------------------------
cp -f "$SRC_DIR/include/nrsc5.h" "$REPO_ROOT/res/nrsc5.h"
echo "==> synced header: res/nrsc5.h"

echo "==> done. Rebuild the app so it links the staged dylib:"
echo "    cargo build --release"
