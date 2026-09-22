import Foundation

/// Prompts and JSON schemas for the three LLM tasks: live tick (standard),
/// live tick (process mapping), and the end-of-meeting finalize pass.
/// String literals versioned with code, not bundle resources.
///
/// Schema constraints (structured outputs): `additionalProperties: false` on
/// every object, every property listed in `required`, optionality expressed
/// via anyOf-with-null, no recursion, no min/max constraints.
enum MeetingPrompts {

    // MARK: - Live tick

    static func liveSystem(mode: MeetingMode) -> String {
        var prompt = """
        You are the note-taking engine inside a meeting recorder. You receive the \
        transcript of an in-progress meeting ("Me" is the app's user; "Them" is the \
        far end of the call) plus the current state as JSON. Return the complete \
        REVISED state.

        Rules for action items:
        - Action items are concrete commitments or follow-ups stated in the meeting.
        - Keep the "id" and "done" fields of items you are not changing. Give new \
        items ids "new-1", "new-2", … Reword an item in place (same id) when the \
        conversation refines it. Remove items that were retracted.
        - Set "owner" to a speaker name only when the transcript makes the owner \
        explicit; otherwise null.
        - The transcript is imperfect speech-to-text: ignore filler, infer obvious \
        intent, never invent commitments that were not made.
        - Return at most 20 items.
        """
        if mode == .processMapping {
            prompt += """


            This is a PROCESS-DISCOVERY call: the speakers are describing how work \
            flows through their organization. You also maintain a swimlane process \
            model.

            - roles: the distinct actors/teams that perform steps (e.g. "Developer", \
            "PM"). Merge synonyms ("dev team" == "Developer"). Keep role ids stable \
            snake-case slugs. Order roles left-to-right in rough order of first \
            involvement.
            - steps: discrete actions, each owned by exactly one role. title <= 6 \
            words, imperative ("Write code"). detail: one clarifying sentence when \
            useful, otherwise null. List steps in the order the process (not the \
            conversation) performs them. Keep step ids stable snake-case slugs.
            - edges: from -> to whenever one step hands off to, triggers, or precedes \
            another. Label an edge only when the handoff has a named artifact or \
            condition ("PR opened", "if QA fails"); otherwise null. Loops/rework \
            edges are allowed.
            - Revise freely: earlier turns are often corrected later ("actually QA \
            happens before deploy"). Keep ids stable for unchanged concepts so the \
            diagram animates rather than rebuilds. Do not include steps that were \
            only hypothetical.
            """
        }
        return prompt
    }

    static func liveSchema(mode: MeetingMode) -> JSONValue {
        var properties: [String: JSONValue] = ["action_items": actionItemsSchema]
        var required: [JSONValue] = ["action_items"]
        if mode == .processMapping {
            properties["process"] = processSchema
            required.append("process")
        }
        return .object([
            "type": "object",
            "additionalProperties": false,
            "required": .array(required),
            "properties": .object(properties),
        ])
    }

    // MARK: - Finalize

    static func finalizeSystem(mode: MeetingMode) -> String {
        var prompt = """
        The meeting has ended. You receive the full transcript ("Me" is the app's \
        user), the user's own rough notes typed during the call, and the running \
        action-item list. Produce the final record.

        - title: <= 8 words, specific ("Acme onboarding process discovery"), no date. \
        When a <calendar_event> block is present the meeting already has a name; \
        still fill the field, but use the event's organizer and attendee names to \
        attribute what was said and to name action-item owners.
        - summary: 2-4 sentences, outcomes first.
        - notes_markdown: polished meeting notes in Markdown. Use the user's rough \
        notes as the backbone — every point they wrote must appear, corrected and \
        expanded with specifics from the transcript (numbers, names, decisions). \
        Then add clearly-separated sections for important topics the rough notes \
        missed. Use ## headings and bullets; bold decisions. Do not include an \
        action-items section (kept separately) and do not fabricate content absent \
        from both inputs.
        - action_items: final deduplicated list. Keep existing ids where the item \
        survives; give new items ids "new-1", "new-2", … Set owner only when \
        explicit in the transcript, otherwise null.
        """
        if mode == .processMapping {
            prompt += """


            - process: the final corrected swimlane process model discussed in the \
            call, following the same rules as during the call (stable snake-case \
            ids; roles ordered by first involvement; steps in process order; edges \
            for handoffs, labeled only for named artifacts or conditions).
            """
        }
        return prompt
    }

    /// The calendar event as prompt text — name, calendar, when, who.
    static func describe(_ e: CalendarEventRef) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, HH:mm"
        var lines = ["title: \(e.title)", "calendar: \(e.calendarTitle) (\(e.account))",
                     "scheduled: \(f.string(from: e.start)) – \(f.string(from: e.end))"]
        if let o = e.organizer { lines.append("organizer: \(o)") }
        if !e.attendees.isEmpty { lines.append("invited: \(e.attendees.joined(separator: ", "))") }
        if let l = e.location { lines.append("location: \(l)") }
        return lines.joined(separator: "\n")
    }

    static func finalizeSchema(mode: MeetingMode) -> JSONValue {
        var properties: [String: JSONValue] = [
            "title": .object(["type": "string"]),
            "summary": .object(["type": "string"]),
            "notes_markdown": .object(["type": "string"]),
            "action_items": actionItemsSchema,
        ]
        var required: [JSONValue] = ["title", "summary", "notes_markdown", "action_items"]
        if mode == .processMapping {
            properties["process"] = processSchema
            required.append("process")
        }
        return .object([
            "type": "object",
            "additionalProperties": false,
            "required": .array(required),
            "properties": .object(properties),
        ])
    }

    // MARK: - Post-hoc process extraction (finished meetings)

    static let processExtractionSystem = """
    You receive the full transcript of a finished meeting ("Me" is the app's \
    user). Extract the business process that was discussed as a swimlane model.

    - roles: the distinct actors/teams that perform steps (e.g. "Developer", \
    "PM"). Merge synonyms ("dev team" == "Developer"). Use stable snake-case \
    slugs as ids. Order roles left-to-right in rough order of first involvement.
    - steps: discrete actions, each owned by exactly one role. title <= 6 \
    words, imperative ("Write code"). detail: one clarifying sentence when \
    useful, otherwise null. List steps in the order the process (not the \
    conversation) performs them. Stable snake-case slug ids.
    - edges: from -> to whenever one step hands off to, triggers, or precedes \
    another. Label an edge only when the handoff has a named artifact or \
    condition ("PR opened", "if QA fails"); otherwise null. Loops/rework edges \
    are allowed.
    - The transcript is imperfect speech-to-text: infer obvious intent, ignore \
    filler, and do not include steps that were only hypothetical.
    - If no organizational process was actually discussed, return empty arrays.
    """

    static let processExtractionSchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": .array(["process"]),
        "properties": .object(["process": processSchema]),
    ])

    // MARK: - Shared schema fragments

    private static let actionItemsSchema: JSONValue = .object([
        "type": "array",
        "items": .object([
            "type": "object",
            "additionalProperties": false,
            "required": .array(["id", "text", "owner", "done"]),
            "properties": .object([
                "id": .object(["type": "string"]),
                "text": .object(["type": "string"]),
                "owner": nullable("string"),
                "done": .object(["type": "boolean"]),
            ]),
        ]),
    ])

    private static let processSchema: JSONValue = .object([
        "type": "object",
        "additionalProperties": false,
        "required": .array(["roles", "steps", "edges"]),
        "properties": .object([
            "roles": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "required": .array(["id", "name"]),
                    "properties": .object([
                        "id": .object(["type": "string"]),
                        "name": .object(["type": "string"]),
                    ]),
                ]),
            ]),
            "steps": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "required": .array(["id", "role_id", "title", "detail"]),
                    "properties": .object([
                        "id": .object(["type": "string"]),
                        "role_id": .object(["type": "string"]),
                        "title": .object(["type": "string"]),
                        "detail": nullable("string"),
                    ]),
                ]),
            ]),
            "edges": .object([
                "type": "array",
                "items": .object([
                    "type": "object",
                    "additionalProperties": false,
                    "required": .array(["from", "to", "label"]),
                    "properties": .object([
                        "from": .object(["type": "string"]),
                        "to": .object(["type": "string"]),
                        "label": nullable("string"),
                    ]),
                ]),
            ]),
        ]),
    ])

    private static func nullable(_ type: JSONValue) -> JSONValue {
        .object(["anyOf": .array([
            .object(["type": type]),
            .object(["type": "null"]),
        ])])
    }
}

// MARK: - Wire payloads (what the schemas decode into)

struct LiveTickPayload: Decodable, Sendable {
    var action_items: [ActionItemPayload]
    var process: ProcessPayload?
}

struct ProcessOnlyPayload: Decodable, Sendable {
    var process: ProcessPayload
}

struct FinalizePayload: Decodable, Sendable {
    var title: String
    var summary: String
    var notes_markdown: String
    var action_items: [ActionItemPayload]
    var process: ProcessPayload?
}

struct ActionItemPayload: Decodable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var done: Bool

    /// Existing UUID ids are preserved; "new-N" ids become fresh UUIDs.
    static func merge(_ payloads: [ActionItemPayload]) -> [ActionItem] {
        payloads.map { p in
            ActionItem(id: UUID(uuidString: p.id) ?? UUID(), text: p.text, owner: p.owner, done: p.done)
        }
    }
}

struct ProcessPayload: Decodable, Sendable {
    struct Role: Decodable, Sendable {
        var id: String
        var name: String
    }
    struct Step: Decodable, Sendable {
        var id: String
        var role_id: String
        var title: String
        var detail: String?
    }
    struct Edge: Decodable, Sendable {
        var from: String
        var to: String
        var label: String?
    }
    var roles: [Role]
    var steps: [Step]
    var edges: [Edge]

    /// Ingest into the app model, dropping references to unknown ids
    /// (sanitized so diagram layout stays a total function).
    func toModel() -> ProcessModel {
        ProcessModel(
            roles: roles.map { ProcessRole(id: $0.id, name: $0.name) },
            steps: steps.map { ProcessStep(id: $0.id, roleID: $0.role_id, title: $0.title, detail: $0.detail) },
            edges: edges.map { ProcessEdge(from: $0.from, to: $0.to, label: $0.label) }
        ).sanitized()
    }
}
