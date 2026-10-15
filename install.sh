#!/usr/bin/env bash
# install.sh — install the quash-recorder CLI from a GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/Oscorp-HQ/quash-releases/main/install.sh | bash -s -- -v <VERSION> -noRoot
#
# What it does:
#   - detects the OS/arch (linux amd64/arm64, macOS Apple Silicon; an Intel
#     Mac is pointed at Docker or a Linux VM);
#   - downloads the release tarball and SHA256SUMS, and ALWAYS verifies the
#     tarball's SHA-256 (a mismatch or a missing entry refuses to install);
#   - when `cosign` is on PATH, ALSO verifies the Sigstore keyless signature
#     of SHA256SUMS against the release workflow's identity, and REFUSES if
#     the signature files are missing or the signature does not verify;
#   - installs to /usr/local/bin (sudo), or $HOME/.quash/bin with -noRoot.
#
# Env vars (testing/override only — a normal user never needs these):
#   QUASH_INSTALL_REPO            default "Oscorp-HQ/quash-releases"
#   QUASH_INSTALL_BASE_URL        default "https://github.com/$QUASH_INSTALL_REPO/releases/download"
#   QUASH_COSIGN_IDENTITY_REGEXP  default: the release workflows of Oscorp-HQ/quash-recorder on a v* tag
set -euo pipefail

REPO="${QUASH_INSTALL_REPO:-Oscorp-HQ/quash-releases}"
BASE_URL="${QUASH_INSTALL_BASE_URL:-https://github.com/${REPO}/releases/download}"
COSIGN_IDENTITY_REGEXP="${QUASH_COSIGN_IDENTITY_REGEXP:-^https://github\\.com/Oscorp-HQ/quash-recorder/\\.github/workflows/(preview-release|release)\\.yml@refs/tags/v[0-9]}"

VERSION=""
NO_ROOT=false
BIN_DIR_OVERRIDE=""

usage() {
  cat <<'USAGE'
usage: install.sh -v VERSION [-noRoot] [-b DIR]

  -v VERSION   release version tag to install (required, e.g. v0.1.0-preview.1)
  -noRoot      install to $HOME/.quash/bin instead of /usr/local/bin (no sudo)
  -b DIR       install to this exact directory instead (testing/advanced use)
  -h, --help   print this message
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v)
      [ $# -ge 2 ] || { echo "install.sh: -v requires a VERSION argument" >&2; usage >&2; exit 2; }
      VERSION="$2"; shift 2 ;;
    -noRoot)
      NO_ROOT=true; shift ;;
    -b)
      [ $# -ge 2 ] || { echo "install.sh: -b requires a DIR argument" >&2; usage >&2; exit 2; }
      BIN_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "install.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "install.sh: -v VERSION is required" >&2
  usage >&2
  exit 2
fi

# --- OS/arch detection --------------------------------------------------
OS_NAME="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "$OS_NAME" in
  Darwin)
    OS=darwin
    IS_ARM64_HW="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
    if [ "$ARCH_RAW" != "arm64" ] && [ "$IS_ARM64_HW" != "1" ]; then
      {
        echo "quash-recorder's native macOS build is Apple Silicon (arm64) only; this Mac reports '$ARCH_RAW'."
        echo "On an Intel Mac, run quash-recorder inside Docker or a Linux VM instead, e.g.:"
        echo "  docker run --rm --platform linux/amd64 ghcr.io/oscorp-hq/quash-recorder:${VERSION} version"
      } >&2
      exit 1
    fi
    ARCH=arm64
    ;;
  Linux)
    OS=linux
    case "$ARCH_RAW" in
      x86_64|amd64) ARCH=amd64 ;;
      aarch64|arm64) ARCH=arm64 ;;
      *)
        echo "install.sh: unsupported Linux architecture: $ARCH_RAW" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "install.sh: unsupported OS: $OS_NAME (quash-recorder ships linux/amd64, linux/arm64, darwin/arm64 only)" >&2
    exit 1
    ;;
esac

# --- install target -----------------------------------------------------
if [ -n "$BIN_DIR_OVERRIDE" ]; then
  TARGET_DIR="$BIN_DIR_OVERRIDE"
  NEED_SUDO=false
elif [ "$NO_ROOT" = "true" ]; then
  TARGET_DIR="$HOME/.quash/bin"
  NEED_SUDO=false
else
  TARGET_DIR="/usr/local/bin"
  NEED_SUDO=true
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quash-install.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

ASSET="quash-recorder_${OS}_${ARCH}.tar.gz"
ASSET_URL="${BASE_URL}/${VERSION}/${ASSET}"
SUMS_URL="${BASE_URL}/${VERSION}/SHA256SUMS"

fetch() {
  # $1 = source URL (http(s):// or file://), $2 = destination path.
  case "$1" in
    file://*)
      cp "${1#file://}" "$2" ;;
    *)
      curl -fsSL -o "$2" "$1" ;;
  esac
}

echo "install.sh: downloading $ASSET_URL" >&2
fetch "$ASSET_URL" "$WORK_DIR/$ASSET"
fetch "$SUMS_URL" "$WORK_DIR/SHA256SUMS"

# --- checksum verification: ALWAYS, never skippable, refuse on mismatch --
# Portable: macOS ships `shasum` (no `sha256sum`); Alpine/busybox ships
# `sha256sum` (no `shasum`).
sha256_check() {
  # $1 = a "sha256  filename" line file to verify, run from its own directory.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$1"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "$1"
  else
    echo "install.sh: neither sha256sum nor shasum is on PATH — cannot verify the download, refusing to install" >&2
    return 1
  fi
}
( cd "$WORK_DIR" && grep -F " ${ASSET}" SHA256SUMS > expected.sum ) || true
if [ ! -s "$WORK_DIR/expected.sum" ]; then
  echo "install.sh: no checksum entry for $ASSET in SHA256SUMS — refusing to install" >&2
  exit 1
fi
if ! ( cd "$WORK_DIR" && sha256_check expected.sum ) >/dev/null 2>&1; then
  echo "install.sh: SHA256 checksum verification FAILED for $ASSET — refusing to install (the download may be corrupted or tampered with)" >&2
  exit 1
fi
echo "install.sh: checksum OK" >&2

# --- cosign verification: when a cosign binary is present on PATH --------
if command -v cosign >/dev/null 2>&1; then
  SIG_URL="${BASE_URL}/${VERSION}/SHA256SUMS.sig"
  PEM_URL="${BASE_URL}/${VERSION}/SHA256SUMS.pem"
  if fetch "$SIG_URL" "$WORK_DIR/SHA256SUMS.sig" 2>/dev/null && \
     fetch "$PEM_URL" "$WORK_DIR/SHA256SUMS.pem" 2>/dev/null && \
     [ -s "$WORK_DIR/SHA256SUMS.sig" ] && [ -s "$WORK_DIR/SHA256SUMS.pem" ]; then
    if cosign verify-blob \
        --certificate "$WORK_DIR/SHA256SUMS.pem" \
        --signature "$WORK_DIR/SHA256SUMS.sig" \
        --certificate-identity-regexp "$COSIGN_IDENTITY_REGEXP" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
        "$WORK_DIR/SHA256SUMS" >/dev/null 2>&1; then
      echo "install.sh: cosign signature OK" >&2
    else
      echo "install.sh: cosign signature verification FAILED for SHA256SUMS — refusing to install" >&2
      exit 1
    fi
  else
    # Every release is signed. Missing signature files with cosign present
    # means the download source dropped them: refuse rather than silently
    # downgrade to checksum-only (a mirror serving its own SHA256SUMS could
    # otherwise pass the checksum step).
    echo "install.sh: cosign is installed but SHA256SUMS.sig/.pem are missing for $VERSION — refusing to install (signature stripped or incomplete release)" >&2
    exit 1
  fi
else
  echo "install.sh: cosign not found on PATH — signature NOT verified (checksum verification above ran and passed). Install cosign (https://docs.sigstore.dev) to verify signatures." >&2
fi

mkdir -p "$WORK_DIR/extract"
tar xzf "$WORK_DIR/$ASSET" -C "$WORK_DIR/extract"
if [ ! -f "$WORK_DIR/extract/quash-recorder" ]; then
  echo "install.sh: $ASSET did not contain a quash-recorder binary — refusing to install" >&2
  exit 1
fi

if [ "$NEED_SUDO" = "true" ]; then
  sudo mkdir -p "$TARGET_DIR"
  sudo install -m 0755 "$WORK_DIR/extract/quash-recorder" "$TARGET_DIR/quash-recorder"
else
  mkdir -p "$TARGET_DIR"
  install -m 0755 "$WORK_DIR/extract/quash-recorder" "$TARGET_DIR/quash-recorder" 2>/dev/null || {
    cp "$WORK_DIR/extract/quash-recorder" "$TARGET_DIR/quash-recorder"
    chmod 0755 "$TARGET_DIR/quash-recorder"
  }
fi

echo "install.sh: quash-recorder $VERSION installed to $TARGET_DIR/quash-recorder" >&2

if [ "$NO_ROOT" = "true" ] && [ -z "$BIN_DIR_OVERRIDE" ]; then
  case ":${PATH:-}:" in
    *":$TARGET_DIR:"*) ;;
    *)
      echo "install.sh: add $TARGET_DIR to your PATH, e.g.:" >&2
      echo "  echo 'export PATH=\"$TARGET_DIR:\$PATH\"' >> ~/.zshrc" >&2
      ;;
  esac
fi

"$TARGET_DIR/quash-recorder" version >&2 || true
