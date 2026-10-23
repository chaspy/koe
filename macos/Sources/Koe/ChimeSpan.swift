import Foundation

// 録音と同じサンプル座標で通知音の区間を表す。音源の後ろ 80ms は出力遅延・残響の余裕。
// 配列長を変えず無音化するので、プリロールや後から鳴る lock_start の位置もずれない。
struct ChimeSpan {
    let start: Int
    let duration: Double

    static func silence(_ samples: [Int16], offset: Int = 0, spans: [ChimeSpan],
                        sampleRate: Double, margin: Double = 0.080) -> [Int16] {
        guard sampleRate.isFinite, sampleRate > 0, margin.isFinite, margin >= 0 else { return samples }
        var result = samples
        for span in spans {
            guard span.start >= 0, span.duration.isFinite, span.duration > 0 else { continue }
            let length = ((span.duration + margin) * sampleRate).rounded(.up)
            let start = Double(span.start) - Double(offset)
            let end = start + length
            guard start < Double(samples.count), end > 0 else { continue }
            let lower = Int(max(0, start))
            let upper = Int(min(Double(samples.count), end))
            for i in lower..<upper { result[i] = 0 }
        }
        return result
    }
}
