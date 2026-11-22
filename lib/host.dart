/// Host CPU affinity (`taskset -c`) and programmatic Linux/host machine noise
/// preflight diagnostics.
library;

export 'src/host/cpu_affinity.dart'
    show CpuAffinity, cpuPinningUnsupportedReason;
export 'src/host/machine_check.dart'
    show HostCheckResult, HostEnvironment, HostWarning, HostWarningKind;
