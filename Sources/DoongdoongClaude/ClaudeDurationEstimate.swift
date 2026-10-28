import Foundation
import DoongdoongAI

/// Claude-only UX heuristics, not measured throughput or a completion deadline.
/// Every model and effort uses these conservative baselines until calibrated.
enum ClaudeDurationEstimate {
    static func duration(for workload: TextGenerationWorkload) -> TimeInterval {
        let characters = Double(max(0, workload.characterCount))
        switch workload.task {
        case .correction:
            return min(3600, max(90, 45 + characters * 0.010))
        case .summary:
            return min(3600, max(45, 30 + characters * 0.003))
        }
    }
}
