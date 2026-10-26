import Foundation

/// CPU time the calling thread has used, in seconds: what a performance bound measures, so other work on the
/// machine (`swift test --parallel`, a build alongside) doesn't make it flake the way wall-clock time does.
public enum ThreadCPUTime {
    public static func seconds() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
