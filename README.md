# Quash recorder — releases

Release files for `quash-recorder`, the Quash API-traffic recorder. This repository holds release downloads and the install script only.

> **Preview.** `v0.0.1-preview.*` builds are early previews for testers. Expect changes.

## Install

Linux (amd64, arm64) and macOS on Apple Silicon:

```sh
curl -fsSL https://raw.githubusercontent.com/Oscorp-HQ/quash-releases/main/install.sh \
  | bash -s -- -v v0.0.1-preview.2 -noRoot
```

- `-noRoot` installs to `$HOME/.quash/bin`. Leave it out to install to `/usr/local/bin` (uses `sudo`).
- On an Intel Mac, run the Linux build in Docker or a Linux VM. The script tells you how.

The script always checks the download's SHA-256 against `SHA256SUMS`, and refuses to install on a mismatch. If [`cosign`](https://docs.sigstore.dev/cosign/system_config/installation/) is installed, it also checks the Sigstore signature of `SHA256SUMS`. It refuses to install if that check fails or the signature files are missing.

## Verify by hand

```sh
# in the folder with the downloaded release files
shasum -a 256 -c SHA256SUMS --ignore-missing
cosign verify-blob \
  --certificate SHA256SUMS.pem --signature SHA256SUMS.sig \
  --certificate-identity-regexp '^https://github\.com/Oscorp-HQ/quash-recorder/\.github/workflows/(preview-release|release)\.yml@refs/tags/v[0-9]' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
```

Each release also carries an SPDX SBOM (`*.spdx.json`) for every binary and container image.

## Known limits of this preview

- The macOS binary is not yet Apple-signed or notarized. Installing with the script works. A binary downloaded in a browser will trigger a Gatekeeper warning.
