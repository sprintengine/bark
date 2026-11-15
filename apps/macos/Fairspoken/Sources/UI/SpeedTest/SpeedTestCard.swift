import FairspokenCore
import FairspokenUI
import SwiftUI

/// Home's speed-test card: an invitation to take the test, or the last result with a retake.
struct SpeedTestCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let test = model.speedTest
        Card(padding: 18) {
            if let last = test.summary.last {
                result(last, best: test.summary.best)
            } else {
                invitation
            }
        }
    }

    private var invitation: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile("gauge.with.needle.fill", color: Crystal.Tile.teal, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("How much faster is your voice?").font(TypeScale.heading).foregroundStyle(Crystal.ink)
                Text("Type a short passage, then read it aloud. About two minutes, and time saved then counts your own typing speed.")
                    .font(TypeScale.body).foregroundStyle(Crystal.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Take the Speed Test") { model.speedTest.begin() }
                .buttonStyle(PrimaryButtonStyle(large: true))
        }
    }

    private func result(_ last: SpeedTest.Record, best: SpeedTest.Record?) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speed test").font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(SpeedTestFormat.multiplier(last.multiplier)).font(.mvNumber(30)).foregroundStyle(Crystal.clientAccent)
                    Text("faster").font(TypeScale.body).foregroundStyle(Crystal.ink2)
                }
                Text(caption(last, best: best)).font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            Rectangle().fill(Crystal.hairline).frame(width: 1, height: 52)
            leg("Typing", wpm: last.typingWpm, seconds: last.typingSeconds, accuracy: last.typingAccuracy, swatch: Crystal.Tile.gray)
            leg("Speaking", wpm: last.speakingWpm, seconds: last.speakingSeconds, accuracy: last.accuracy, swatch: Crystal.clientAccent)
            Spacer(minLength: 8)
            Button("Retake") { model.speedTest.begin() }
                .cardButton()
                .help("Type and read a new passage")
        }
    }

    private func leg(_ title: String, wpm: Int, seconds: Double?, accuracy: Int?, swatch: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Crystal.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(wpm)").font(.mvNumber(20)).foregroundStyle(Crystal.ink)
                Text("wpm").font(TypeScale.meta).foregroundStyle(Crystal.ink2)
            }
            Text(detail(seconds: seconds, accuracy: accuracy)).font(.system(size: 11)).foregroundStyle(Crystal.ink3).lineLimit(1)
        }
        .frame(minWidth: 110, alignment: .leading)
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
