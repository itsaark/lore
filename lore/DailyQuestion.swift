import CryptoKit
import Foundation

struct DailyQuestion: Equatable, Sendable {
    let id: String
    let text: String

    var textKey: String { Self.textKey(for: text) }

    static func followUp(_ text: String) -> DailyQuestion {
        DailyQuestion(id: "follow-up:" + textKey(for: text), text: text)
    }

    private static func textKey(for text: String) -> String {
        let normalized = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let evergreen: [DailyQuestion] = [
        .init(id: "e01", text: "What’s a small part of today you can still picture?"),
        .init(id: "e02", text: "What’s a sound you hear most mornings?"),
        .init(id: "e03", text: "What do you notice on a route you take often?"),
        .init(id: "e04", text: "What snack could you pick out by smell alone?"),
        .init(id: "e05", text: "What’s something within reach that has a story?"),
        .init(id: "e06", text: "What song brings a place to mind?"),
        .init(id: "e07", text: "What’s a meal you remember mostly for how it tasted?"),
        .init(id: "e08", text: "Where could you find your way around in the dark?"),
        .init(id: "e09", text: "What’s an everyday object you remember using years ago?"),
        .init(id: "e10", text: "What does a day off look like when you get one to yourself?"),
        .init(id: "e11", text: "Where did you go when you wanted a little time to yourself as a kid?"),
        .init(id: "e12", text: "What could you see from a window you knew well as a child?"),
        .init(id: "e13", text: "How did you spend a rainy day when you were little?"),
        .init(id: "e14", text: "What’s a game you remember playing as a kid?"),
        .init(id: "e15", text: "What did a familiar street look like when you were growing up?"),
        .init(id: "e16", text: "What food reminds you of a particular person?"),
        .init(id: "e17", text: "What saying do you remember hearing at home?"),
        .init(id: "e18", text: "What’s something your family did in its own way?"),
        .init(id: "e19", text: "What’s a song you remember somebody else playing?"),
        .init(id: "e20", text: "What piece of clothing can you still picture from years ago?"),
        .init(id: "e21", text: "What’s a room you’d recognize from just one detail?"),
        .init(id: "e22", text: "What did the start of a shift look like at a job you remember well?"),
        .init(id: "e23", text: "What’s a task someone once showed you how to do?"),
        .init(id: "e24", text: "What do you remember about the first day of a job or project?"),
        .init(id: "e25", text: "What’s a piece of work you remember finishing?"),
        .init(id: "e26", text: "How did you get to know a place that was new to you?"),
        .init(id: "e27", text: "What sound do you associate with somewhere you used to live?"),
        .init(id: "e28", text: "What did an ordinary afternoon with an old friend look like?"),
        .init(id: "e29", text: "What’s a story you can still hear someone telling in their own voice?"),
        .init(id: "e30", text: "What’s a day that started out ordinary and took a turn?"),
        .init(id: "e31", text: "What do you remember about going back to a place after years away?"),
        .init(id: "e32", text: "What do you remember about taking on something you weren’t sure you could do?"),
        .init(id: "e33", text: "What’s a moment when someone made room for you?"),
        .init(id: "e34", text: "What’s a conversation that changed what you did next?"),
        .init(id: "e35", text: "What’s a routine you once thought would always be part of your life?"),
        .init(id: "e36", text: "What’s a time you changed your mind about what you wanted?"),
        .init(id: "e37", text: "What do you remember about a time your plans took you somewhere unexpected?"),
        .init(id: "e38", text: "What’s a moment that shows how someone shaped the way you do things?"),
        .init(id: "e39", text: "What’s something from an earlier part of your life you still do the same way?"),
        .init(id: "e40", text: "What’s an ordinary scene you’d want someone years from now to be able to picture?"),
    ]
}

struct DailyQuestionPresentation: Equatable, Identifiable, Sendable {
    let dayKey: String
    let question: DailyQuestion
    let sourceDayStoryID: UUID?

    var id: String { dayKey }
}
