# Installer sandbox tests

Run from the checkout, without root:

```sh
python3 installer/tests/run.py
bash -n installer/install.sh
shellcheck -S warning installer/install.sh
```

Requires x86-64 Linux, Bubblewrap with unprivileged user namespaces, Python 3,
a C compiler, and the ordinary shell tools used by the installer. Individual
cases can be passed to `run.py`, for example `virtio double-signal`.

The harness executes the real `installer/install.sh` directly, without copying,
rewriting, sourcing, or extracting its functions. Bubblewrap provides private
`/dev`, `/proc`, `/sys`, `/etc`, `/mnt`, and `/tmp` views; the host filesystem is
read-only. Installer commands that access devices, the network, mounts, packages,
or the target chroot are stubs on PATH. A seccomp filter also denies socket
creation. No host block devices are bound into the sandbox.

Because device-node creation is unavailable in the development sandbox,
`fake-block.c` makes only the two regular placeholder files `/dev/vda1` and
`/dev/vda2` appear as block devices to `stat`. It does not open devices or change
installer logic. All test files are created under `installer/tests/` and removed
when the runner exits.

The successful virtio case has neither SERIAL nor WWN and must complete all 14
steps, unmount, and exit 0. Further cases cover absent diskseq, changed size,
serial, WWN and diskseq, recoverable disk-selection errors, literal boot-argument
globs, dry-run output and absence of writes, and cancellation before log creation.

The signal case sends two actual Ctrl+C bytes to the installer's controlling
terminal, 50 ms apart, during pacstrap. That stub needs one second after TERM to
release five nested mounts. Tests require its cleanup to complete, both installer
mounts to be unmounted exactly once, exit 130, and an interruption report. They
check for surviving worker and spinner processes before the PID namespace exits.
The spinner-failure case requires its distinct error and exit status 42.

Input cases queue text and Enter during packages and check the terminal is empty
at both the replacement-username prompt and the final reboot prompt. Reboot keeps
its default Yes. Unmount cases cover transient and persistent busy errors, the
explicit `umount -R /mnt` recovery instruction, and target-keyring daemon cleanup
before the root unmount. The reboot stub requires all mounts to be gone.

These are integration tests of installer control flow with simulated external
commands, not VM tests of actual partitioning, pacstrap, GnuPG, or bootability.
