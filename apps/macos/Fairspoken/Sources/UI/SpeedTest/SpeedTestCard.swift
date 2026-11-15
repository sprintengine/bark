import FairspokenCore
import FairspokenUI
import SwiftUI

/// Home's speed-test card, in the side column: an invitation to take the test, or the last
/// result (how many times faster speaking was, each leg's pace) with a retake.
struct SpeedTestCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let test = model.speedTest
        Card(cornerRadius: 26, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Speed test", symbol: "gauge.with.needle")
                if let last = test.summary.last {
                    result(last, best: test.summary.best)
                } else {
                    invitation
                }
            }
        }
    }

    private var invitation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How much faster is your voice?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Crystal.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Type a short passage, then read it aloud. About two minutes, and time saved can then count your own typing speed.")
                .font(.system(size: 13)).foregroundStyle(Crystal.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Take the Speed Test") { model.speedTest.begin() }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .padding(.top, 2)
        }
    }

    private func result(_ last: SpeedTest.Record, best: SpeedTest.Record?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SpeedTestFormat.multiplier(last.multiplier)).font(.mvNumber(40, weight: .bold))
                        .foregroundStyle(Crystal.clientAccent)
                    Text(last.multiplier >= 1 ? "faster speaking" : "as fast speaking").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Crystal.ink2)
                }
                Text(caption(last, best: best)).font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .top, spacing: 12) {
                leg("Typing", wpm: last.typingWpm, seconds: last.typingSeconds, accuracy: last.typingAccuracy, swatch: Crystal.ink3.opacity(0.7))
                leg("Speaking", wpm: last.speakingWpm, seconds: last.speakingSeconds, accuracy: last.accuracy, swatch: Crystal.clientAccent)
            }
            HStack(spacing: 10) {
                Button("Retake") { model.speedTest.begin() }
                    .cardButton()
                    .controlSize(.small)
                    .help("Type and read a new passage")
                if model.speedTest.typingSpeedInUse != nil {
                    Button("Use a typical \(Int(UsageStats.typingWPM)) wpm") { model.speedTest.useTypicalTypingSpeed() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Crystal.clientAccent)
                        .lineLimit(1)
                        .help("Count time saved on Home against a typical typing pace instead of yours")
                }
            }
        }
    }

    private func leg(_ title: String, wpm: Int, seconds: Double?, accuracy: Int?, swatch: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Crystal.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(wpm)").font(.mvNumber(22, weight: .bold)).foregroundStyle(Crystal.ink)
                Text("wpm").font(.system(size: 11)).foregroundStyle(Crystal.ink2)
            }
            Text(detail(seconds: seconds, accuracy: accuracy)).font(.system(size: 11)).foregroundStyle(Crystal.ink3)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(seconds: Double?, accuracy: Int?) -> String {
        [seconds.map { SpeedTestFormat.clock($0) }, accuracy.map { "\($0)% accurate" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func caption(_ last: SpeedTest.Record, best: SpeedTest.Record?) -> String {
        let when = "Measured \(last.date.formatted(.relative(presentation: .named)))"
        if let best, best.multiplier > last.multiplier + 0.05 {
            return "\(when) · best \(SpeedTestFormat.multiplier(best.multiplier))"
        }
        return when
    }
}
