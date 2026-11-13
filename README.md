# runs-on-vz

`runs-on-vz` is the minimal Virtualization.framework driver used by RunsOn's
macOS Fleet hosts. It runs Tart-format macOS VM bundles without installing Tart
on customer infrastructure.

The CLI is intentionally narrow and machine-oriented:

```text
runs-on-vz clone --source IMAGE --destination VM [--keep-mac --keep-ecid] --json
runs-on-vz run --vm VM --cpus 4 --memory-mib 8192 --save-state --json
runs-on-vz run --vm VM --cpus 4 --memory-mib 8192 --restore-state --bootstrap-file FILE --detach --json
runs-on-vz run --vm VM --cpus 6 --memory-mib 15360 --detach --json
runs-on-vz run --vm VM --cpus 4 --memory-mib 8192 --bootstrap-file EXECUTION_DIR/channel.json --detach --json
runs-on-vz ip --vm VM --json
runs-on-vz wait --vm VM --json
runs-on-vz stop --vm VM --grace-seconds 30 --json
runs-on-vz delete --vm VM --json
```

Commands reject unknown, duplicate, and command-inapplicable options. Output is
always JSON; `--json` is accepted but optional.

- Success exits 0 and writes one JSON object with `"ok":true` to stdout.
  `ip` adds an `ip` field. Only a foreground `run` (without `--detach`) also
  writes progress lines to stderr; a detached VM logs to `VM/run.log`.
- Failure exits nonzero and writes
  `{"ok":false,"error":{"kind":"…","message":"…"}}` to stderr. Nothing is
  written to stdout.

Callers should decode the success envelope from stdout only and the failure
envelope from stderr only, so a wrapper's diagnostics (such as `launchctl` or
`sudo` output) cannot corrupt either. Treat malformed output, a missing `ok`,
or `ok:false` without an error kind and message as a contract error. Key
decisions on `error.kind`, not on the exit status value.

Each clone uses APFS `clonefile(2)` and receives a distinct MAC address and Mac
machine identifier. VMs are headless, use NAT networking, and expose their IP
through the host DHCP lease database.

`--bootstrap-file` serves one host-owned snapshot over this VM's virtio socket
on port 1024. Each guest connection receives the current file and EOF. There
are no request parameters, network listener, or shared filesystem. Use a new
private host directory for each execution. Atomically replace the snapshot
when credentials renew; never reuse its path for another execution.

The guest connects to `VMADDR_CID_HOST` (2), port 1024. Payloads must be nonempty
regular files of at most 64 KiB; symlinks are rejected. Each listener permits
at most eight concurrent replies, with a five-second socket write timeout.
Never include host credentials or another execution's data in the snapshot.

`wait` observes process exit without contacting the guest. The runtime writes a
terminal result before a clean or failed VM process exits. Missing, malformed,
or mismatched results fail instead of turning crashes into successful waits.
Process records contain both the PID and its kernel start time, so recovery never
treats a reused PID as the VM. `stop` confirms exit before removing that record.
A detached child cannot start its VM until its parent durably records its
identity. Malformed process records fail closed; inspect them before cleanup.

Clone, start, stop and delete serialize through a kernel lock on the VM directory.
A command blocked on that lock re-verifies the directory inode once it acquires
the lock; a replacement at the same path is not the same VM, and the command
fails instead. `wait` takes no lock, because it lasts as long as the VM and
must not block `stop`. It binds to the process identity recorded when it
starts and accepts only a result written by that process. If the directory is
replaced or deleted meanwhile, `wait` reports that process's own result or
fails with `stale_result` or `unexpected_exit`; it never reports another VM's
outcome.

Clone directory creation is exclusive, so a losing clone cannot remove another
clone's files. A short parent-directory lock protects creation through opening
the new inode, and directory removal. It is not held during VM startup or
shutdown. The host agent sets the clone's owner explicitly before starting the
dedicated console user's runtime.

The socket replaces virtiofs bootstrap, which macOS privacy protection blocks
when accessed by a daemon at cold boot. Two simultaneous Sequoia 15.6.1 guests
successfully read distinct harmless markers from their own sockets at boot.
No SSH job dispatch or additional privacy grants were used.

Virtualization.framework operations must run inside an unlocked Aqua session.
RunsOn launches the CLI as a dedicated non-admin console user; calling `run`
from a system LaunchDaemon without a GUI session fails on stock macOS images.

## Saved states

A VM can be saved once it is running and restored many times, which skips
macOS's boot (about 35 s) for a restore (4 to 8 s from an SSD):

```text
runs-on-vz run --vm TEMPLATE --cpus 3 --memory-mib 6144 --save-state --json
runs-on-vz clone --source TEMPLATE --destination VM --keep-mac --keep-ecid --json
runs-on-vz run --vm VM --cpus 3 --memory-mib 6144 --restore-state --bootstrap-file FILE --detach --json
```

- `run --save-state` boots the VM in the foreground, without a bootstrap
  file, and waits up to 10 minutes for the guest's first connection to port
  1024: the guest is then waiting for its document. It refuses that
  connection, lets the guest settle for 3 s, pauses the VM, writes
  `VM/state.vzvmsave` (its memory and devices: 2.4 GB for a macOS 26 guest
  of 6 GiB) and powers it off. The disk and NVRAM stay as they were saved.
- `clone` copies `state.vzvmsave` with the disk (APFS clones). A restore
  needs the configuration it was saved with: the same MAC address, machine
  identifier, CPUs and memory (another MAC or identifier fails with "invalid
  argument"). `--keep-mac --keep-ecid` keep them. Two VMs restored from one
  state share an address, so a host keeps one saved state per concurrent VM.
- `run --restore-state` restores `VM/state.vzvmsave` instead of booting and
  logs `restored in N ms`. The guest resumes where it was saved: it asks for
  its document again and gets the bootstrap file's.
- A VM that is saved or restored has no sound or entropy device (the
  framework cannot save them). Its bootstrap replies add
  `"runs-on-vz":{"time_ms":…,"seed":"…"}` to the payload's object: the
  host's clock and 32 random bytes, for a resumed guest to set its clock and
  stir its random pool, both as they were when it was saved.
- The framework encrypts a saved state with a Secure Enclave key in the
  console user's keychain: saving needs that account to hold a secure token
  (`sysadminctl -secureTokenStatus`), and restoring needs its keychain
  unlocked, so its screen lock must be off (`sysadminctl -screenLock off`):
  a locked session refuses restores with "permission denied" about 5
  minutes after it locks. A state restores only on the Mac and account that
  saved it.
- The framework reads a state with small uncached reads: 7.6 s for 2.4 GB
  from a Mac's internal SSD, 4.1 s from a RAM disk, 33 to 50 s from an EC2
  Mac's EBS volume. Keep states on the internal SSD.

## Upgrading from v0.1

v0.2.0 is a breaking release. Callers written for v0.1.x must change:

- `clone` no longer accepts `--slot`. v0.1.x ignored it; v0.2.0 rejects it,
  like any unknown option, with exit status 64 and kind `unknown_option`.
- Every command now rejects unknown, duplicate and inapplicable options
  instead of ignoring them.
- Failures now write `{"ok":false,"error":{"kind":"…","message":"…"}}`.
  v0.1.x wrote `{"error":{"code":"…","message":"…"}}` without `ok`.
- `wait` and `run --bootstrap-file` are new. Hosts that start execution-bound
  guests need both, so they cannot run on v0.1.x.

The RunsOn host agent requires v0.2.0 or newer. Its adapter never sends
`--slot`, starts VMs with `run --detach` (adding `--bootstrap-file` for
execution-bound guests), and holds `wait` open for each VM's lifetime. It
decodes `{"ok":true}` from stdout on exit 0 and the `ok:false` envelope from
stderr on a nonzero exit, and treats anything else as a contract error. It
does not call `ip`.

## Build

Build on Apple Silicon with macOS 14 or newer:

```bash
swift build -c release --arch arm64
```

Virtualization.framework requires its caller to hold the
`com.apple.security.virtualization` entitlement. Sign a local build ad hoc
with it (no certificate needed):

```bash
Scripts/sign.sh .build/arm64-apple-macosx/release/runs-on-vz
```

Release binaries are signed this way already, and the signature travels with
the binary: a host downloads `runs-on-vz-darwin-arm64`, checks it against its
SHA-256 file and runs it. They are not notarized, so download them with a
tool that sets no quarantine attribute (`curl`), not a browser.

The release workflow reruns unit, process and lifecycle checks on the signed
binary before publishing it and its SHA-256 file. Run it on `main` with the
version to release (Actions, Release, Run workflow): it creates the tag.
Pushing a `v*` tag releases that tag instead. Versions with a prerelease
suffix, such as `v0.2.0-rc.1`, publish a prerelease without changing the
latest stable release. A version is never published twice.

## Tests

`swift test` requires full Xcode, including XCTest. The `Test` workflow runs
unit tests, builds the runtime and runs the process and lifecycle checks below
on a GitHub-hosted Mac for every branch and pull request. It does not start a
VM.

With Command Line Tools alone, build the runtime and run the process check:

```bash
swift build -c release --arch arm64
swiftc Sources/runs-on-vz/ProcessIdentity.swift Sources/runs-on-vz/RunResult.swift Scripts/process-identity-smoke.swift -o /tmp/process-identity-smoke
/tmp/process-identity-smoke "$PWD/.build/arm64-apple-macosx/release/runs-on-vz"
```

The check creates and stops its own temporary sleep process. It verifies
process identity, stale PID protection, waiting, stopping and record cleanup.

The lifecycle check uses invalid bundles that cannot pass VM configuration
validation. It checks command serialization, replacement protection, launcher
authorization, concurrent clones, distinct identities and isolated disk writes:

```bash
swiftc -parse-as-library Scripts/lifecycle-smoke.swift -o /tmp/lifecycle-smoke
/tmp/lifecycle-smoke "$PWD/.build/arm64-apple-macosx/release/runs-on-vz"
```
