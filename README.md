# runs-on-vz

`runs-on-vz` is the minimal Virtualization.framework driver used by RunsOn's
macOS Fleet hosts. It runs Tart-format macOS VM bundles without installing Tart
on customer infrastructure.

The CLI is intentionally narrow and machine-oriented:

```text
runs-on-vz clone --source IMAGE --destination VM --slot 0 --json
runs-on-vz run --vm VM --cpus 6 --memory-mib 15360 --detach --json
runs-on-vz run --vm VM --cpus 4 --memory-mib 8192 --bootstrap-file EXECUTION_DIR/channel.json --detach --json
runs-on-vz ip --vm VM --json
runs-on-vz stop --vm VM --grace-seconds 30 --json
runs-on-vz delete --vm VM --json
```

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
