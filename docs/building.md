# Building Gilgamesh

Use the full checkout. The [build guide](../build/README.md) is the local command
reference; the [CI guide](../ci/README.md) covers publication, signing, recovery and
adding packages. Builds download Arch packages and upstream sources and require network
access. The checked-in recipes and workflows are not evidence of a published release.

## Local packages and ISO

Use a Linux host with Bash, coreutils, `flock`, and Docker available to the invoking
user. The wrapper uses Podman if Docker is absent; see the build guide for user-namespace
constraints. Commands run from the repository root:

```sh
build/build.sh pkg gilgamesh-settings
build/build.sh repo
build/build.sh pkg gilgamesh-shell
build/build.sh kernel
build/build.sh repo
build/build.sh pkg nvidia-open-tkg
build/build.sh repo
build/build.sh iso
```

Index settings before building shell, and index the kernel/headers before building
NVIDIA. Package archives and the local database land in `repo/x86_64/`; cache and
kernel diagnostics live in `build/cache/`; ISO output goes to `out/`. Local repository
output is unsigned. Published repository signing is a separate CI step.

The wrapper builds the container image when missing and refreshes Arch in each
invocation. Package builds use disposable containers and a read-only source checkout.
ISO building uses a **privileged container** for archiso. Allow at least 25 GB for
the kernel build, plus space for the live filesystem and ISO. Follow the
[kernel guide](../kernel/README.md) to inspect the actual build config and logs.

Existing package archives are never overwritten: bump the package release first.
For a same-version kernel rebuild, pass `PKGREL=N` with a positive release higher than
the previous one, then rebuild the matching NVIDIA package. The tkg source commit is
pinned, but kernel point releases and Arch dependencies still move.

The [ISO guide](../iso/README.md) covers staging and boot tests. The image bundles the
Bash installer and its adjacent configs from the same checkout. tty1 starts it after
network preparation; `gilgamesh-install` retries from the live shell. Installation
requires UEFI and network access; BIOS boot is provided for rescue.

**Release integration remains unfinished:** the live profile and installer currently
select stock Arch `linux`; the installer selects `nvidia-open-dkms` for supported
NVIDIA devices. Neither is wired to the signed Gilgamesh repository yet. Building the
custom packages first does not automatically change those selections. The public
signing certificate at `keys/gilgamesh.asc` is also not present in this checkout.

## Automated repository

[GitHub Actions workflows](../.github/workflows) check upstream every six hours at
minute 17 UTC, rebuild changed inputs on main, and build pull requests with read-only
credentials. Markdown changes are excluded from package source hashes. CI does not
build an ISO or import AUR recipes automatically. It builds settings before shell,
and publishes kernel, headers and matching NVIDIA modules together.

The publisher is designed to serve signed packages and databases from the mutable
release tagged `repo`. The configured pacman URL has no architecture suffix; after
the reviewed public key is installed and trusted, the CI guide specifies this entry
above `[core]`:

```ini
[gilgamesh]
SigLevel = Required DatabaseRequired
Server = https://github.com/haider-IQZ/gilgamesh/releases/download/repo
```

That is the publication layout, not a claim that the repository is live. The CI guide
supersedes the placeholder hosting/signing TODOs in the local build guide. GitHub
Releases database replacement is not atomic; clients can briefly see a missing asset
or signature mismatch during publication. See CI's recovery and rollback procedures.

## Owner setup

Follow [Signing and owner setup](../ci/README.md#signing-and-owner-setup) in order:

1. Keep the repository public, enable Actions and leave default token permissions
   read-only. Keep `GILGAMESH_PUBLISH_ENABLED` unset or false. Allow the publisher's
   `GITHUB_TOKEN` to fast-forward main under branch/ruleset policy; no PAT is required.
2. Keep the `repo` release mutable. Let CI create it; do not seed an unsigned database.
3. Create a dedicated signing key offline. Add only its reviewed public certificate
   at `keys/gilgamesh.asc` and integrate trust import into the installer. Keep the
   primary secret and revocation material offline.
4. Create the `pacman-repo` deployment environment, restricted to main with tags
   excluded, and require an owner/reviewer initially. Store `GILGAMESH_GPG_KEY` (the
   armored secret signing-subkey export) and `GILGAMESH_GPG_PASSPHRASE` (nonempty)
   as environment secrets; remove repository-level copies. Set the environment variable
   `GILGAMESH_GPG_FINGERPRINT` to the full uppercase primary fingerprint.
5. Manually dispatch **Update packages** on main with `rebuild=all` while publication
   is disabled. Inspect build artifacts, logs and generated kernel config. This
   rehearsal does not sign, publish or advance state.
6. Only after the rehearsal passes, set repository variable
   `GILGAMESH_PUBLISH_ENABLED=true`. Dispatch `rebuild=all` again, approve deployment,
   and verify release signatures and a disposable pacman client. Retain required
   review until the first publications are verified.

Read the CI guide for key generation, rotation, failed-build retries and rollback.
Its local validation entry point is `bash ci/validate.sh`; it reports missing optional
linters. A hosted rehearsal, actual package installation and disposable ISO boot/install
tests remain necessary to validate the full release path.
