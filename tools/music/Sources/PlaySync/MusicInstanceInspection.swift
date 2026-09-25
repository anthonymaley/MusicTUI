import Darwin

/// What is known about one specific Music.app instance, identified by its pid
/// and start time.
///
/// Only `.exited` is a verified exit. `.unknown` never counts as one.
enum MusicInstanceState: Equatable {
    case alive
    case exited
    case unknown
}

/// The errno from a failed process inspection. 0 means the inspection returned
/// less than a full record.
struct ProcessInspectionErrno: Error, Equatable {
    let code: Int32
}

/// Answers whether one exact Music.app instance is still running.
protocol MusicInstanceInspecting {
    func state(of process: MusicProcess) -> MusicInstanceState
}

/// The start time of a process, in seconds since 1970 with microsecond
/// precision (`seconds + microseconds / 1_000_000`), or the errno on failure.
///
/// A short read reports a failure with code 0. Callers that build a `MusicProcess`
/// use this same value, so start times compare exactly.
func processStartTime(pid: Int32) -> Result<Double, ProcessInspectionErrno> {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    errno = 0
    let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    if written <= 0 {
        return .failure(ProcessInspectionErrno(code: errno))
    }
    if written < size {
        return .failure(ProcessInspectionErrno(code: 0))
    }
    return .success(Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
}

/// Pure: turns one inspection of a pid into the instance's state.
///
/// - the same start time: the instance is still running;
/// - a different start time: the pid now belongs to another process, so the
///   instance has exited;
/// - no such process: the instance has exited;
/// - any other failure: unknown, which is never treated as an exit.
func classifyInstance(_ inspection: Result<Double, ProcessInspectionErrno>, expectedStart: Double) -> MusicInstanceState {
    switch inspection {
    case .success(let start):
        return start == expectedStart ? .alive : .exited
    case .failure(let error):
        return error.code == ESRCH ? .exited : .unknown
    }
}

/// Inspects the live process table.
struct ProcMusicInstanceInspector: MusicInstanceInspecting {
    func state(of process: MusicProcess) -> MusicInstanceState {
        classifyInstance(processStartTime(pid: process.pid), expectedStart: process.startedAt)
    }
}
