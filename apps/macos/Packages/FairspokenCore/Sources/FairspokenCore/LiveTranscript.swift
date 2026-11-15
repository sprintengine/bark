import Foundation

/// Text shown while the user is still speaking: how decoded pieces join into running text,
/// and how much of it fits the recording pill.
public enum LiveTranscript {
    /// Joins decoded pieces (finished segments, then the live tail) into running text.
    /// Parakeet punctuates every piece as if it were a whole utterance, so a piece cut
    /// mid-sentence ends with a full stop and the next one starts in lower case
    /// ("mild shortness." + "of breath"); that full stop is dropped.
    public static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            let clean = collapse(piece)
            guard !clean.isEmpty else { continue }
            if out.isEmpty {
                out = clean
                continue
            }
            if let first = clean.first, first.isLetter, first.isLowercase, out.hasSuffix("."), !out.hasSuffix("..") {
                out.removeLast()
            }
            out += " " + clean
        }
        return out
    }

    /// The end of `text` in at most `maxCharacters` characters, so the newest words are the
    /// ones on screen. A cut lands on a word boundary and is marked with a leading ellipsis;
    /// a single word longer than the budget is cut mid-word.
    public static func displayTail(_ text: String, maxCharacters: Int) -> String {
        let clean = collapse(text)
        guard maxCharacters > 1, clean.count > maxCharacters else { return maxCharacters > 1 ? clean : "" }
        var tail = Substring(clean.suffix(maxCharacters - 1))
        let cutMidWord = clean.dropLast(tail.count).last.map { !$0.isWhitespace } ?? false
        if cutMidWord, let space = tail.firstIndex(where: \.isWhitespace), tail[space...].contains(where: { !$0.isWhitespace }) {
            tail = tail[space...]
        }
        return "…" + tail.drop(while: \.isWhitespace)
    }

    /// Whitespace (including line breaks) collapsed to single spaces, ends trimmed.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// True when a stretch of audio holds nothing a decode could turn into new words
    /// (below `RecordingGate`'s silence thresholds).
    public static func isQuiet(_ samples: ArraySlice<Float>) -> Bool {
        guard !samples.isEmpty else { return true }
        var sum: Float = 0
        var peak: Float = 0
        for s in samples {
            sum += s * s
            peak = max(peak, abs(s))
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms < RecordingGate.silenceRMS * 2 && peak < RecordingGate.silencePeak * 2
    }
}

/// Where to cut the live tail into a finished segment. Parakeet sees 15 s windows, so once
/// 12 s are waiting the audio is cut at the quietest 20 ms between 7 and 12 s (a pause between
/// words), as Fairspoken Server's `StreamSegmenter` does; the segment is decoded once and only
/// the newer audio is decoded again as the user keeps speaking.
public struct LiveSegmenter: Sendable, Equatable {
    public var triggerSeconds = 12.0
    public var earliestCutSeconds = 7.0
    public var windowSeconds = 0.02

    public init() {}

    /// Number of leading samples to cut off as a finished segment, or nil to keep growing.
    public func cutPoint(_ samples: ArraySlice<Float>, sampleRate: Int) -> Int? {
        let rate = Double(sampleRate)
        let trigger = Int(triggerSeconds * rate)
        guard samples.count >= trigger else { return nil }
        let window = max(1, Int(windowSeconds * rate))
        var best = trigger
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = Int(earliestCutSeconds * rate)
        let base = samples.startIndex
        while i + window <= trigger {
            var energy: Float = 0
            for k in (base + i)..<(base + i + window) { energy += samples[k] * samples[k] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = i + window / 2
            }
            i += window
        }
        return best
    }
}
