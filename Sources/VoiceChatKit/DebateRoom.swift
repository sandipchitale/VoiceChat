import Foundation

// A debate room: a motion, a seat per debater, and the wording handed to each
// of them. The person creates the room in the menu bar; MCP clients take the
// seats by id. Nothing here knows about windows, AppKit or the protocol — the
// text belongs with the rules so both can be tested without either.

public struct DebateSeat: Sendable, Codable, Equatable, Identifiable {
    /// What a joining client passes as `side`. Short and typable: "for".
    public var key: String
    /// How the seat is named on screen: "For the motion".
    public var name: String
    /// The stance this seat argues.
    public var position: String
    /// A system voice name or identifier, if the person chose one.
    public var voice: String?

    public var id: String { key }

    public init(key: String, name: String, position: String, voice: String? = nil) {
        self.key = key
        self.name = name
        self.position = position
        self.voice = voice
    }
}

/// A client's claim on a seat, carried on `session.open`.
public struct DebateJoin: Sendable, Codable, Equatable {
    public var roomID: String
    /// The seat key the client asked for.
    public var seat: String

    public init(roomID: String, seat: String) {
        self.roomID = roomID
        self.seat = seat
    }
}

public struct DebateRoom: Sendable, Codable, Equatable {
    /// Short and memorable, because a person types it into another app.
    public var id: String
    public var motion: String
    /// Seats speak in order; the first seat opens. Two for now, but the order
    /// is a rotation, so a third seat is a setting rather than a rewrite.
    public var seats: [DebateSeat]
    /// Statements before closing arguments begin.
    public var maxStatements: Int
    /// Optional house rules, e.g. "Keep each statement under 120 words."
    public var guidance: String?

    public init(id: String = DebateRoom.makeID(), motion: String, seats: [DebateSeat],
                maxStatements: Int = 10, guidance: String? = nil) {
        self.id = id
        self.motion = motion
        self.seats = seats
        self.maxStatements = maxStatements
        self.guidance = guidance
    }

    public func seat(_ key: String) -> DebateSeat? { seats.first { $0.key == key } }
    public var openingSeat: DebateSeat? { seats.first }

    /// The seat after `key`, wrapping around.
    public func seat(after key: String) -> DebateSeat? {
        guard let index = seats.firstIndex(where: { $0.key == key }) else { return nil }
        return seats[(index + 1) % seats.count]
    }

    // MARK: Identity

    private static let words = ["owl", "fox", "elm", "koi", "ram", "yak", "ibis", "wren",
                                "lynx", "moth", "sage", "tern"]

    /// e.g. `owl-42`. Short enough to read aloud and retype in another app.
    public static func makeID() -> String {
        "\(words.randomElement() ?? "owl")-\(Int.random(in: 10...99))"
    }

    // MARK: The wording

    /// The rules every statement is written under. Sent once, at the top of a
    /// seat's first prompt.
    public func briefing(for seat: DebateSeat) -> String {
        var lines = [
            "You are taking part in a spoken debate.",
            "",
            "Motion: \(motion)",
            "You are \(seat.name), and you argue this position and only this position: \(seat.position)",
            "",
            "Begin every statement by naming yourself in one short sentence, so a listener knows who is speaking.",
            "Write for the ear: short sentences, no headings, no bullet lists, no code blocks. It will be read aloud.",
            "Argue on the merits. Never concede the debate and never break character to comment on the exercise.",
            "A line beginning \"> Moderator:\" comes from the human moderator. Do as it asks.",
        ]
        let houseRules = guidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !houseRules.isEmpty { lines.append(houseRules) }
        return lines.joined(separator: "\n")
    }

    /// The first seat's prompt, once every seat is taken.
    public func openingPrompt(for seat: DebateSeat) -> String {
        briefing(for: seat) + "\n\nYou open the debate. Give your opening statement now."
    }

    /// A statement arriving from another seat. The first one a seat receives
    /// carries the briefing, because that seat has not been told the rules yet.
    public func relay(_ statement: String, from speaker: DebateSeat, to listener: DebateSeat,
                      includeBriefing: Bool) -> String {
        let body = "\(speaker.name) said:\n\n\(statement)\n\nAnswer it."
        return includeBriefing ? briefing(for: listener) + "\n\n" + body : body
    }

    /// The last word for a seat.
    public func closingPrompt(_ statement: String?, from speaker: DebateSeat?,
                              to listener: DebateSeat) -> String {
        var body = ""
        if let statement, let speaker {
            body += "\(speaker.name) said:\n\n\(statement)\n\n"
        }
        return body + "This is the final exchange. Give your closing statement now."
    }

    /// Wraps whatever the moderator typed, so a debater can tell the human's
    /// words from its opponent's.
    public static func moderatorLine(_ text: String) -> String {
        "> Moderator: " + text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "\n> ")
    }

    /// Marks the moderator's own words inside a statement they edited before
    /// sending it, so the debater can tell the human's words from its
    /// opponent's. Text that came through untouched is passed through
    /// unchanged; anything else is attributed.
    public static func markModeratorEdits(sent: String, delivered: String?) -> String {
        let sentTrimmed = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let delivered, !delivered.isEmpty else { return sentTrimmed }
        let deliveredTrimmed = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        if sentTrimmed == deliveredTrimmed { return sentTrimmed }

        guard let range = sentTrimmed.range(of: deliveredTrimmed) else {
            // The statement was replaced outright: all of this is the human.
            return moderatorLine(sentTrimmed)
        }
        let before = String(sentTrimmed[sentTrimmed.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(sentTrimmed[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if !before.isEmpty { parts.append(moderatorLine(before)) }
        parts.append(deliveredTrimmed)
        if !after.isEmpty { parts.append(moderatorLine(after)) }
        return parts.joined(separator: "\n\n")
    }

    /// What the person pastes into another MCP host to fill a seat.
    public func joinInstruction(for seat: DebateSeat) -> String {
        """
        Join the VoiceChat debate "\(id)" as the "\(seat.key)" side: call the `converse` tool with \
        debate_id "\(id)" and side "\(seat.key)" on your first call, then keep the conversation \
        going until it ends. The motion is: \(motion)
        """
    }
}
