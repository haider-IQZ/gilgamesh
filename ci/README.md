# Automated package repository

This pipeline builds the reviewed Gilgamesh PKGBUILDs and the pinned linux-tkg recipe,
signs the successful output, and serves pacman from the mutable GitHub release tagged
`repo`. It uses `build/build.sh pkg <dir>`, `kernel-stack`, and `repo`, with output in
`repo/x86_64`. It does not build an ISO or import AUR recipes automatically.

The repository **must be public**: pacman downloads release assets anonymously,
and public repositories receive the 4-vCPU hosted runners this kernel budget needs.
Private repositories' 2-vCPU runners will not make the kernel budget.

## What runs when

| Entry point | Work | Credentials |
| --- | --- | --- |
| `update.yml`, every six hours at minute 17 (UTC) | Check upstream; build affected packages except unchanged failed attempts | Read token during planning/building; signing and write access only in publication |
| `update.yml`, manual dispatch on main | Build-only bootstrap while disabled; otherwise same, optionally force packages or `all` | Same |
| `build.yml`, push to main | Rebuild changed inputs; increment `pkgrel` only for the same published upstream version | Same |
| `build.yml`, `pull_request` | Build changed content against the PR merge checkout | Read-only token; no signing secrets, publication, commits, or issues |

Push builds, scheduled builds, reporting, recovery and publication are disabled until
repository variable `GILGAMESH_PUBLISH_ENABLED` is exactly `true`. An explicit manual
dispatch may run the read-only bootstrap while disabled; PR checks may also run.
Pushing the CI files with empty state therefore cannot launch an automatic bootstrap.

`pipeline.yml` is the shared **read-only build workflow**. `publish.yml` is called only
by the main-branch entry points; its publisher has `contents: write` and `issues: write` (to close resolved issues),
and its separate failure reporter has `issues: write`. PRs cannot call a write-capable reusable workflow
through these entry points. There is no `pull_request_target` or cross-run artifact lookup.
Artifacts are downloaded only from the same workflow run and checked against the plan's SHA.
All third-party actions are pinned to full commit SHAs, with version comments.

Both main workflows share the **whole-run** concurrency group
`gilgamesh-repository-main`, with cancellation disabled. This covers planning through
publication, including calls to the reusable workflows. PRs have separate groups
and cancel superseded PR runs.
GitHub can replace pending runs; the scheduler compares content hashes to the last
successful publication, so a skipped/coalesced push does not lose changes. Publication fetches `origin/main`, requires the tracked state file to be unchanged,
and checks each unit's source hash at that head against its plan. Unrelated commits
are preserved: the bot builds its commit on top of the fetched head. Changed units
(and their kernel/driver pair) are skipped, without failure records, for the next run.
A final head check and normal fast-forward push guard subsequent races. A no-op run
returns successfully if main moved; it cleans assets only while its head still matches. Never run two manual publishers outside Actions.

The initial `state.json` is empty: the first manual run bootstraps every package.
After that, only affected packages are selected. Pushes do not independently upgrade
unaffected upstream packages. `ci/packages.json` maps shipped source directories:

- `gilgamesh-settings`: `system/`, `scripts/gilgamesh-dns`, `etc/sudoers.d/gilgamesh-dns`.
- `gilgamesh-shell`: `quickshell/`, `hypr/hyprland.lua`, and the three shipped fish files.
- `linux-tkg`: `kernel/customization.cfg`, `kernel/gilgamesh.myfrag`, and `kernel/check-config.sh`.
- Every unit tracks `build/Dockerfile`, `build/*.sh`, `build/check-sources.awk`, and `build/makepkg.conf.d/`;
  each package also tracks its own `packages/<name>/` directory.
- `*.md` files are excluded everywhere. Build caches and unshipped config/docs are
  excluded. CI/workflow edits can trigger a cheap plan but do not change source hashes.

Hashes include file names, contents, executable bits, symlink targets and deletions.
Local `gilgamesh-*` packages have manual nvchecker entries and no external version
lookup. Their PKGBUILD is authoritative for `pkgver`.

`linux-tkg` tracks the numerically newest **7.2.x point release** in kernel.org's
`v7.x` directory. The separate manual `tkg` entry must match the full commit pinned
in `build/container.sh`; CI never changes this pin. CI passes the plan's exact
`KERNEL_VERSION` to both `kernel-check` and the build wrapper. The external config
requires that value and selects its `v7.2.x` tag, with no floating default. CI checks
the **actual built version** against the plan; kernel and headers must match. A same-upstream kernel
rebuild uses `PKGREL` above the last published release, with upstream 273 as its floor.
A new kernel upstream starts at 273. Ordinary first releases retain their recipe
release (normally 1); upgrades reset it to 1, and only same-upstream rebuilds bump it.
No local kernel PKGBUILD is invented or generated.

NVIDIA's version comes directly from Arch's **extra/x86_64/nvidia-utils** JSON
endpoint, rather than NVIDIA's tags. The local recipe's `nvidia-utils=$pkgver` and
`nvidia-open-dkms=$pkgver` constraints must resolve in the build container; mirror
skew records a failure; retry after the mirror catches up with an explicit forced rebuild.
Update mode bumps the NVIDIA recipe to its planned version before kernel preflight;
push/PR mode keeps the recipe's pin. Changing either the kernel or NVIDIA selects
both, including same-upstream rebuilds. They build through one `kernel-stack` run,
sharing installed tools and fixed official databases. Preflight retains the exact
`nvidia-utils` and `nvidia-open-dkms` archives before compilation. CI validates their
versions and carries them and any detached signatures in the result artifact's
`inputs/` directory, separately from locally built publication outputs.
NVIDIA's output must declare an exact dependency on the built kernel version.
Any stack failure fails both result records. Kernel, headers and NVIDIA publish as one unit. Settings
build before shell when both are affected. Dependency components build in parallel;
a failed settings build blocks the selected shell, but a failed shell does not hold
back successfully built settings.

## Local recipe updates and adding packages

`ci/bump.sh <package> <version> [--rebuild]` validates the reviewed local recipe,
compares versions with Arch `vercmp`, sets `pkgver`, resets `pkgrel=1` for an upgrade,
and runs `updpkgsums` inside the image built from `build/Dockerfile`. A same-version
`--rebuild` increments the integer `pkgrel` and leaves checksums alone. Downgrades
are refused. A checksum failure restores the original PKGBUILD. It writes no
`.SRCINFO` or other generated recipe files; `--printsrcinfo` is only a validation pipe.

For an AUR package, copy and **review** its PKGBUILD, install script, patches, source
URLs and license first. Keep those files in `packages/<name>/`. Add a source entry
in `nvchecker.toml`, for example:

```toml
[example]
source = "aur"
aur = "example"
strip_release = true
```

Prefer the actual upstream release source when practical. Add the package to
`ci/packages.json` with `sources` (additional shipped directories) and `after`
(local build dependency units). CI checks registry coverage and topologically orders
connected dependencies. Include newly mapped source paths in `build.yml`'s path filters.
Keep kernel dependency components small enough to fit the kernel job's time limit;
other components have 100 minutes. Literal `pkgver` and positive integer `pkgrel`
assignments are required for automated bumps. Split packages are supported when the
main output has the directory's name; removing outputs requires a reviewed migration.
Do not give two package units ownership of the same output package.

`ci/aur-diff.sh <aur-pkgbase> <our-directory>` fetches a recipe into a temporary file
and prints a diff for human review. It never executes or installs that recipe, opens
a PR, or changes our copy. Upstream AUR `pkgrel` edits are intentionally not imported.

Before and after checksum updates, evaluated `.SRCINFO` must have matching source /
checksum counts. Every remote non-VCS source needs SHA-256 or stronger; **any `SKIP`
for such a source fails**. Architecture-specific arrays and renamed sources are
checked. VCS sources may use `SKIP`; pin their commit in the reviewed recipe whenever
possible. Local source files and packages assembled entirely from this checkout do
not need remote-source hashes. The pinned tkg PKGBUILD is audited in a fresh checkout cached only within the job
at `build/cache/linux-tkg` before invoking the kernel wrapper; an upstream recipe incompatible with
this checksum policy fails visibly and needs deliberate review, not an automatic
weakening of the policy. Arch dependencies retain pacman's upstream signature checks.

Force a rebuild using **Actions → Update packages → Run workflow → rebuild**:
`gilgamesh-shell`, `linux-tkg`, `nvidia-open-tkg`, comma-separated directories, or `all`.
For kernel config/tkg pin changes, edit the reviewed files and use the push workflow.
To change kernel series, update the config, nvchecker regex and CI's version guard
together. Do not use a scheduled update to advance the tkg commit.

## Release layout and pacman configuration

Put this **above `[core]`** on x86_64 machines after installing and trusting the
Gilgamesh public key:

```ini
[gilgamesh]
SigLevel = Required DatabaseRequired
Server = https://github.com/haider-IQZ/gilgamesh/releases/download/repo
```

There is **no `/$arch` suffix**: release assets have a flat namespace. pacman requests
`gilgamesh.db` and `gilgamesh.db.sig` relative to this Server URL, then the package
filenames recorded in that database. This is the fixed-tag download URL, not a
`/releases/tag/` page or `/releases/latest/download/` URL.

The release contains:

- Current package archives and detached `.sig` files.
- One previous archive/signature per output package for rollback.
- `gilgamesh.db.tar.zst`, `gilgamesh.files.tar.zst` and their detached signatures.
- Real byte-for-byte copies named `gilgamesh.db`, `gilgamesh.files` and their `.sig`
  aliases. Symlinks are never uploaded.
- Current and previous `snapshot-<run>-<attempt>.tar.gz` database snapshots. Each
  contains the eight database assets above, already signed; its SHA-256 is in Git.
- A temporary `ci-transaction.json` only while publishing or awaiting recovery.

GitHub [renames special characters in asset names and requires deletion before
replacement](https://docs.github.com/en/rest/releases/assets#upload-a-release-asset).
CI forbids epochs, `+`, and other unsafe filename characters; it validates both
`.PKGINFO` and actual archive names. It also checks uploaded names, sizes and downloaded
SHA-256 values, paginates asset lists, retries uploads, and replaces any asset whose state is not `uploaded` (including `open` and `starter`). A fixed tag avoids the ambiguity of GitHub's
[latest-release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
The tag must stay **mutable**; repository release immutability is incompatible with
this design. Do not attach unrelated files with managed package/snapshot names.

`repo-add --sign --verify --include-sigs` verifies the existing database before
updating, includes package signatures, and signs the new database. CI also signs and
verifies the files database and checks that indexed filenames exactly match the
intended current set. It keeps previous archives out of the database and removes older
unreferenced managed assets after a successful Git push. See the
[repo-add manual](https://man.archlinux.org/man/repo-add.8) and
[pacman.conf manual](https://man.archlinux.org/man/pacman.conf.5).

## Signing and owner setup

Before the first run, in this order:

1. Make the repository **public** and enable Actions. Keep default workflow token
   permissions **read-only**; job-level permissions grant the required writes. Keep
   `GILGAMESH_PUBLISH_ENABLED` unset/false throughout setup. Permit the publisher's
   `GITHUB_TOKEN` to fast-forward `main` under branch/ruleset policy; no PAT is needed.
2. Leave the fixed `repo` release mutable; CI creates it when publishing. Do not
   manually publish an unsigned initial database.
3. Create the dedicated key offline, commit its reviewed public certificate at
   `keys/gilgamesh.asc`, and integrate its import into the installer. This CI-only
   change does not create that certificate or alter installer trust.
4. Create deployment environment **`pacman-repo`**. Restrict deployment branches to
   **main only**, exclude tags, and require an owner/reviewer for the first runs.
   Store `GILGAMESH_GPG_KEY` (ASCII-armored secret signing-subkey export) and
   `GILGAMESH_GPG_PASSPHRASE` (nonempty passphrase) **in this environment**. Delete any
   repository-level copies. Set environment variable `GILGAMESH_GPG_FINGERPRINT` to
   the full uppercase primary fingerprint. The publish job reads these directly;
   callers never pass reusable-workflow signing secrets. Only the signing step gets
   GPG variables; publication/Git/API operations do not.
5. Manually run **Update packages** on main with `rebuild=all` while publishing is
   disabled. This is a build-only bootstrap rehearsal. Inspect all build artifacts,
   kernel logs/config and checks; resolve failures before proceeding. It intentionally
   does not sign, update state or create the release.
6. **Last setup step:** set repository variable **`GILGAMESH_PUBLISH_ENABLED=true`**.
   Then dispatch Update packages with `rebuild=all`, approve the environment deployment,
   and verify the release signatures and a disposable pacman client. The first signed
   run builds again because the rehearsal did not advance state. Keep the required
   reviewer until the first publications are verified; remove it only when ready for
   unattended publication. Schedules are now enabled, but environment review still
   gates signing/publication while configured.

On an offline machine with a fresh GnuPG home on encrypted removable storage, create
a certification-only primary key and a signing subkey. These are examples; run them
interactively so GnuPG prompts for a strong passphrase:

```bash
umask 077
export GNUPGHOME=/path/on/encrypted/offline-volume/gilgamesh-gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --quick-generate-key 'Gilgamesh Linux package signing' ed25519 cert 2y
gpg --list-keys --with-subkey-fingerprint
# Replace PRIMARY_FINGERPRINT below with the complete primary fingerprint.
gpg --quick-add-key PRIMARY_FINGERPRINT ed25519 sign 1y
gpg --armor --export PRIMARY_FINGERPRINT > gilgamesh.asc
gpg --armor --export-secret-subkeys PRIMARY_FINGERPRINT > gilgamesh-signing-subkeys.asc
```

Keep the primary secret, revocation certificate and backup offline. Transfer only
the signing-subkey export through an encrypted channel into the Actions secret,
then remove the temporary export. Never commit it, paste it into a command argument,
or add it to an artifact. The signing helper uses a temporary directory, a read-only
container secret mount, loopback GPG with a passphrase file, and cleanup traps. Builds
never receive signing material. No secret values are in these files.

Import the reviewed public certificate on the installed system as root, after
checking its fingerprint through an independent trusted channel:

```bash
pacman-key --add /path/to/gilgamesh.asc
pacman-key --finger PRIMARY_FINGERPRINT
pacman-key --lsign-key PRIMARY_FINGERPRINT
```

An installer should ship the reviewed `keys/gilgamesh.asc` rather than downloading
trust material from an unverified moving branch. Prefer a dedicated keyring package
for future automated trust distribution. Do not enable `SigLevel = Never` for the
published repository; the build wrapper's unsigned **local-only** dependency index is
separate and its downloaded packages are verified before use.

For rotation, distribute the new public certificate to clients while the old key
still works (or add/renew a signing subkey under the same offline primary). During a
primary-key transition, `keys/gilgamesh.asc` must contain both public certificates so
CI can verify the old repository and retained packages. Update the secret export,
passphrase and pinned primary fingerprint together; verify a manual publication and
client trust, then retire the old signer. Keep old public keys available as long as
retained signatures need verification. For compromise, revoke and distribute the
revocation through a trusted channel; re-sign/rebuild affected packages after review.

nvchecker reads a temporary keyfile through `NVCHECKER_KEYFILE`; `nvcheck.sh` writes
`[keys]."github.com"` from `GH_TOKEN` and deletes the file on exit. The workflow uses
its short-lived read-only `GITHUB_TOKEN`. This is nvchecker's documented
[keyfile mechanism](https://nvchecker.readthedocs.io/en/latest/usage.html#configuration-table),
not a token embedded in the tracked TOML. Current kernel/Arch/manual entries need no
GitHub API token; the mechanism is ready for reviewed GitHub version sources.

## Failures, recovery and rollback

Each build captures its full output in Actions and a per-package artifact log. Image,
disk and dependency setup have `setup.log`; missing artifacts/timeouts become explicit
failure records. On main, the reporter opens or updates the exact issue title
`build failed: <pkg> <version>` with the last 100 log lines (bounded in size) and a run
link. Existing matching open issues are updated instead of creating duplicates.
A successful build held for its pair uses
`held back: <pkg> <version> (waiting for <pair>)`, not a build-failure title.
Successful publication automatically closes that unit's open failure/held-back issues.
PR failures appear in check results and artifacts and do not write issues.

Failed packages do not contribute recipes, nvchecker versions or archives to publication.
Their `(unit, version, source hash)` tuples are committed in `ci/state.json`, including
runs with no successes. This keeps suppression in the same fast-forward transaction
as successful state, avoiding a separately mutable failures release asset. Identical
failures are skipped until their version/source changes or dispatch forces a rebuild.
A held-back unit is not recorded as failed; its pair stays suppressed together until
retry is eligible (forcing `linux-tkg` also forces the driver).
Successful independent groups still publish even when another job fails. Kernel or
NVIDIA failure holds both back. Upstream-check/configuration errors fail planning;
signing, GitHub API, and permission failures fail the publication check. These
infrastructure errors surface in Actions, not as invented package build failures.
Enable workflow-failure notifications. Logs/artifacts expire after 14 days.

Tracked `oldver.json` and `newver.json` contain **only successful versions** after
publication; the observed candidate file is transient until then. `state.json` records
actual package versions, hashes, source hashes, output ownership and rollback records.
Only successful PKGBUILDs and those three state files enter the bot commit; a
failure-only commit changes just `ci/state.json`. Before copying any artifact recipe,
the publisher rejects changes beyond literal `pkgver`, `pkgrel` and checksum arrays
compared with fetched HEAD. `/work` is read-only in CI containers: checksums can write
only their package directory; nvchecker writes only artifacts, and the kernel check
can write only its within-job checkout. Signing can write only the prepared repo. The commit
uses `[skip ci]`; the default token also does not trigger recursive push workflows.

Publication uploads immutable packages/signatures and a complete snapshot first,
then records a recovery journal and uploads all eight DB assets as `*.new`.
Only after every staged upload verifies does it delete each old asset and PATCH the
staged asset's name to its live name, then pushes the prepared state commit to main. A rejected push or failed replacement
restores the previous DB snapshot; a bootstrap failure removes the incomplete aliases.
A runner kill leaves the journal for the next trusted publisher. Recovery checks
whether the exact commit reached main, keeping the new DB if it did, otherwise
restoring the old one. Recovery runs before reading the new run's artifacts, including
when those are missing. Unreferenced package uploads are removed before the next
attempt so rebuilding the same version cannot be blocked by an orphaned asset.
If recovery itself loses network access, the journal remains for another attempt.

**GitHub Releases cannot atomically replace a database and detached signature.**
During replacement, CDN propagation, or an interrupted run, pacman may see a brief
404/signature mismatch and must retry. Embedded package signatures and retained old
archives prevent this from silently accepting bad packages. If zero interruption is
a requirement, use hosting that supports atomic directory/symlink switches; the
fixed-tag Releases interface cannot offer that guarantee. A hard-killed publisher
can require the next run or operator recovery to restore service.

For an individual client rollback, download the previous archive **and its signature**
listed in `ci/state.json` from the fixed release URL, verify the signature, then use
`pacman -U` as root with those files. Roll kernel, headers and NVIDIA back together;
NVIDIA also needs the matching `nvidia-utils` version (and applicable 32-bit userspace).
Do this in a rescue environment if the installed driver/kernel is unusable. Review
other dependent package compatibility rather than forcing pacman past dependency errors.

For an emergency whole-repository rollback:

1. Disable the schedule/push workflow, wait for any active publisher, and resolve any
   `ci-transaction.json` first. With a trusted checkout and write-scoped `GH_TOKEN`,
   `GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch python3 ci/pipeline.py recover`
   repairs an interrupted transaction. Do not clear the journal by hand first.
2. Identify the last good bot commit and the corresponding snapshot in its
   `ci/state.json`. The latest state's `previous_snapshot` identifies the immediately
   preceding database. Download it, verify its recorded SHA-256, inspect the tar
   members, and verify both database signatures against the trusted public key.
3. Replace **all eight** DB assets from that snapshot (real files under both aliases
   and compressed names), keeping the old package/signature assets. Use the same
   fixed release. This has the same non-atomic replacement window described above.
4. Restore the matching PKGBUILDs and three CI state files from the good commit and
   commit the rollback to main with `[skip ci]`. Do not rewind unrelated source changes
   or force-push history. Keep automation disabled until the offending sources are
   fixed, otherwise upstream discovery can immediately select the bad update again.
5. Rebuild the fix with a release greater than **any version already installed by
   clients**, including the withdrawn one. Clients do not automatically downgrade:
   use the explicit client rollback procedure where needed. Verify before re-enabling
   automation. Previous snapshots/packages are a one-generation rollback window,
   not an archival backup service; save an external copy for longer retention.

## Hosted runner resources and validation

Every job is pinned to `ubuntu-24.04`; Kernel/NVIDIA runs on its own job. It removes only listed preinstalled
toolchains using a disposable root container (no host sudo) and requires at least
32 GiB free on the workspace filesystem before building. CI builds the **same `build/Dockerfile`** base, then one derived `ci/Dockerfile` image
per job with Python, PyYAML, nvchecker, pyalpm and pacman-contrib baked in. Utility
containers do not repeat upgrades/tool installs. The build wrapper upgrades Arch
once per build run; `repo` only refreshes the local database. Kernel-check uses a
separate pinned tkg checkout for source policy; kernel-stack prepares its own fresh
tree and checks the resolved config and kernel version before compiling.
The source check is capped at 10 minutes, the shared kernel/NVIDIA build at 305,
and the job at 350. That leaves 35 minutes for recipe bumps, image/setup/artifacts
(31 after the two possible 2-minute kill grace periods). Expect roughly 4–5 hours for a
cold kernel/driver run on a public 4-vCPU runner; the first hosted rehearsal must
measure this estimate. Private 2-vCPU runners will not make this budget. A job timeout
cannot publish incomplete output.

There is deliberately **no cross-run ccache/tkg source cache**: tkg resets tracked
files but can retain untracked patches and settings; accepting a PR-produced cache
would add a code-injection path. Within a job, the documented `build/cache` is used.
This favors fresh, auditable builds over cache speed. Arch mirrors and the base image
remain rolling, just as in the documented local interface; action pins and the tkg
commit do not imply bit-for-bit reproducibility.

Run the offline validation from the repository root:

```bash
bash ci/validate.sh
```

It runs Bash syntax checks, Python compilation, TOML/JSON/PyYAML parsing, workflow
policy checks, ShellCheck and actionlint when available, and mocked script/fault tests.
Missing optional linters are explicitly reported. Planning also runs Bash syntax,
unit tests and the workflow policy checks on every workflow run. Tests create their temporary
fixtures only under ignored `ci/artifacts/` and never perform real builds, commits,
pushes, workflow runs, signing, or GitHub writes. The first hosted manual run remains
necessary to validate actual container/upstream integration and owner credentials.

Action pins use the supplied reviewer-verified Node 24 revisions: checkout v7.0.1,
upload-artifact v7.0.1, download-artifact v8.0.1. Offline review checked every supplied
input: checkout `fetch-depth`/`persist-credentials`; upload `name`, `path`,
`if-no-files-found`, `retention-days`, `compression-level`; download `name`/`path`.
No downloaded action manifests are present to independently confirm those majors'
input schemas or runtime behavior; verify these on the bootstrap rehearsal. Checkout
credentials persist only in the publisher, where fetch/push needs them.
