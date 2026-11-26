import Foundation

/// The word lists the cleanup rules use. Everything is lowercase with straight apostrophes.
///
/// The structure follows the usual account of a self-repair in speech: a reparandum (what is
/// taken back), an optional interregnum (a filler or an editing term such as "I mean",
/// "sorry", "no wait") and the repair. Lists of editing terms and filled pauses follow the
/// conventions of published conversational-speech disfluency annotation; the word classes used
/// to type-align a repair with its reparandum (days, months, numbers, names, noun phrases) are
/// our own, kept deliberately small so that a rule only fires when it is sure.
enum CleanupLexicon {
    /// Filled pauses, always fillers. ("mm" is millimetres and "uh-huh" is a yes: neither is here.)
    static let hardFillers: Set<String> = ["um", "umm", "ummm", "uh", "uhh", "uhm", "er", "erm", "ehm", "hmm", "hmmm", "hm"]

    static let determiners: Set<String> = [
        "a", "an", "the", "my", "your", "our", "his", "her", "their", "its", "this", "that", "these", "those",
        "some", "another", "any", "each", "every", "no",
    ]

    static let subjectPronouns: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "i'm", "i'll", "i've", "i'd", "we're", "we'll", "we've",
        "you're", "you'll", "he's", "she's", "they're", "it's", "there's", "that's", "let's",
    ]

    static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am", "have", "has", "had", "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must", "won't", "can't",
        "don't", "doesn't", "didn't", "isn't", "wasn't", "aren't", "weren't", "wouldn't", "couldn't", "shouldn't",
        "going", "gonna", "got", "need", "needs", "want", "wanted", "wants",
    ]

    static let prepositions: Set<String> = [
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into", "onto", "over", "under",
        "after", "before", "between", "through", "during", "without", "within", "towards", "around", "until", "till",
    ]

    static let conjunctions: Set<String> = ["and", "but", "or", "nor", "so", "because", "if", "when", "while", "that", "than", "then", "whether", "where", "which", "who", "what", "how", "why"]

    /// Words a sentence cannot end on: a full stop after one is a pause, not an ending.
    static let cannotEndSentence: Set<String> = [
        "a", "an", "the", "of", "and", "or", "but", "nor", "my", "your", "our", "their", "its", "than",
        "because", "whether", "every", "each",
    ]

    /// Words after which a clause is clearly unfinished: a fragment ending on one was abandoned.
    static let incompleteEnd: Set<String> = determiners
        .union(subjectPronouns).union(auxiliaries).union(prepositions).union(conjunctions)
        .subtracting(["that", "this", "these", "those", "some", "any", "no", "it", "what", "who", "why", "how", "need", "needs", "want", "wanted", "wants", "got", "going", "then", "so"])

    /// Function words: a capital on one after a comma is a pause artefact, and they are not
    /// "content" when counting what cleanup removed.
    static let functionWords: Set<String> = determiners.union(subjectPronouns).union(auxiliaries)
        .union(prepositions).union(conjunctions)
        .union(["not", "just", "also", "as", "there", "here", "me", "him", "them", "us", "too", "very", "really", "then", "now"])

    /// Words a single-word repeat of is a stutter ("the the", "I I I"). Content words and the
    /// grammatical doubles ("had had", "that that", "is is", "you you", "her her") are left alone.
    static let stutterWords: Set<String> = [
        "the", "a", "an", "i", "we", "they", "he", "she", "to", "of", "at", "for", "with", "and",
        "but", "or", "my", "your", "our", "their", "this", "if", "because", "can", "will", "would", "should",
        "could", "i'm", "i'll", "i've", "i'd", "it's", "we're", "we'll", "there's", "what", "when", "where",
        "how", "are", "were", "am", "have", "has", "just", "it", "from", "be", "into",
    ]

    /// Repeated phrases that are emphasis, not a restart.
    static let emphaticPhrases: Set<String> = [
        "i know", "come on", "go on", "well done", "thank you", "hurry up", "oh my", "oh dear", "oh no",
        "my god", "you know", "hang on", "hold on", "wait a minute", "not now", "never again", "excuse me",
        "listen to me", "look at me", "slow down", "calm down", "shut up", "see you", "bye now", "all right",
        "right right", "okay okay", "yes please", "no thanks", "thank you so much", "thanks very much",
    ]

    /// Clause openers before a repeated phrase that make the repeat grammatical ("If you can,
    /// you can come").
    static let subordinators: Set<String> = [
        "if", "when", "whenever", "as", "because", "since", "while", "though", "although", "unless", "until",
        "before", "after", "once", "whether", "wherever", "whatever", "however",
    ]

    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mondays", "tuesdays", "wednesdays", "thursdays", "fridays", "saturdays", "sundays",
    ]
    static let relativeDays: Set<String> = ["today", "tomorrow", "tonight", "yesterday"]
    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]

    static let numberWords: Set<String> = [
        "zero", "nought", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
        "million", "billion", "half", "quarter", "dozen", "noon", "midday", "midnight",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "twentieth", "thirtieth",
    ]

    /// Units and time markers that may follow a number ("50 mg", "3 pm", "five o'clock").
    static let units: Set<String> = [
        "pm", "am", "a.m", "p.m", "o'clock", "euro", "euros", "pound", "pounds", "quid", "dollar", "dollars",
        "percent", "cent", "cents", "pence", "p", "k", "grand", "minute", "minutes", "mins", "min", "hour",
        "hours", "hrs", "day", "days", "week", "weeks", "month", "months", "year", "years", "mg", "milligrams",
        "mcg", "micrograms", "ml", "millilitres", "kg", "kilos", "kilograms", "g", "grams", "metres", "meters",
        "miles", "km", "kilometres", "litres", "seconds", "secs", "units", "tablets", "times", "mmol", "mmhg",
    ]

    /// Words that may appear between a cue and a repair, or between the repair and a unit, and
    /// that the repair may repeat ("on Tuesday, sorry, on Wednesday").
    static let repairPrefixes: Set<String> = [
        "on", "at", "by", "in", "for", "from", "to", "until", "till", "before", "after", "next", "this",
        "last", "around", "about", "maybe", "say",
    ]

    /// Words that may follow a repair and still leave it a repair rather than a new clause.
    static let followsRepair: Set<String> = [
        "at", "on", "in", "for", "with", "and", "or", "then", "instead", "please", "if", "because", "so",
        "to", "by", "from", "until", "till", "before", "after", "but", "as", "of", "rather", "morning",
        "afternoon", "evening", "night", "week", "thanks", "next", "this", "the", "a",
    ]

    /// Capitalised words that are not names.
    static let notNames: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "the", "a", "an", "this", "that", "it", "it's", "we", "you", "he",
        "she", "they", "my", "our", "your", "his", "her", "their", "there", "here", "what", "when", "where",
        "who", "why", "how", "yes", "no", "ok", "okay", "so", "and", "but", "or", "if", "then", "let's", "let",
        "please", "thanks", "thank", "sorry", "hi", "hello", "dear", "well", "actually", "also", "just",
        "can", "could", "would", "should", "will", "is", "are", "was", "were", "do", "does", "did", "maybe",
        "great", "good", "fine", "right", "see", "send", "tell", "ask", "call", "meet", "on", "at", "in",
        "wait", "mean", "scratch", "correction", "rather",
    ]

    static let titles: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "professor", "sir", "madam", "father", "sister"]
}
