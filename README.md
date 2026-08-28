# runs-on-vz

`runs-on-vz` is the minimal Virtualization.framework driver used by RunsOn's
macOS Fleet hosts. It runs Tart-format macOS VM bundles without installing Tart
on customer infrastructure.

The CLI is intentionally narrow and machine-oriented:

```text
runs-on-vz clone --source IMAGE --destination VM --slot 0 --json
runs-on-vz run --vm VM --cpus 6 --memory-mib 15360 --detach --json
runs-on-vz ip --vm VM --json
runs-on-vz stop --vm VM --grace-seconds 30 --json
runs-on-vz delete --vm VM --json
```

Each clone uses APFS `clonefile(2)` and receives a distinct MAC address and Mac
machine identifier. VMs are headless, use NAT networking, and expose their IP
through the host DHCP lease database.

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
