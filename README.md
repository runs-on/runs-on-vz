# runs-on-vz

`runs-on-vz` is the minimal Virtualization.framework driver used by RunsOn's
macOS Fleet hosts. It runs Tart-format macOS VM bundles without installing Tart
on customer infrastructure.

The CLI is intentionally narrow and machine-oriented:

```text
runs-on-vz clone --source IMAGE --destination VM --json
runs-on-vz run --vm VM --cpus 6 --memory-mib 15360 --detach --json
runs-on-vz run --vm VM --cpus 4 --memory-mib 8192 --bootstrap-file EXECUTION_DIR/channel.json --detach --json
runs-on-vz ip --vm VM --json
runs-on-vz wait --vm VM --json
runs-on-vz stop --vm VM --grace-seconds 30 --json
runs-on-vz delete --vm VM --json
```

Commands reject unknown, duplicate, and command-inapplicable options. Failures
exit nonzero and write `{"ok":false,"error":{"kind":"…","message":"…"}}`.
Callers must treat malformed output or a false `ok` value as a contract error.

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
A waiter verifies the directory inode after acquiring that lock; a replacement
at the same path is not the same VM. Clone directory creation is exclusive, so
a losing clone cannot remove another clone's files. A short parent-directory
lock protects creation through opening the new inode, and directory removal.
It is not held during VM startup or shutdown. The host agent sets the
clone's owner explicitly before starting the dedicated console user's runtime.

The socket replaces virtiofs bootstrap, which macOS privacy protection blocks
when accessed by a daemon at cold boot. Two simultaneous Sequoia 15.6.1 guests
successfully read distinct harmless markers from their own sockets at boot.
No SSH job dispatch or additional privacy grants were used.

Virtualization.framework operations must run inside an unlocked Aqua session.
RunsOn launches the CLI as a dedicated non-admin console user; calling `run`
from a system LaunchDaemon without a GUI session fails on stock macOS images.

## Build

Build on Apple Silicon with macOS 14 or newer:

```bash
swift build -c release --arch arm64
```

Release binaries are unsigned. The RunsOn host agent applies an ad-hoc
signature with the virtualization entitlement before first use.

The release workflow reruns unit, process and lifecycle checks before publishing
the arm64 binary and its SHA-256 file. Tags containing a prerelease suffix,
such as `v0.2.0-rc.1`, publish a prerelease without changing the latest stable
release. Publication requires an existing remote tag.

## Tests

`swift test` requires full Xcode, including XCTest. The `Test` workflow runs
unit tests, builds the runtime and checks process recovery on a GitHub-hosted
Mac for every branch and pull request. It does not start a VM.

With Command Line Tools alone, build the runtime and run the process check:

```bash
swift build -c release --arch arm64
swiftc Sources/runs-on-vz/ProcessIdentity.swift Scripts/process-identity-smoke.swift -o /tmp/process-identity-smoke
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
