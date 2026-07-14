import Foundation

/// Best-effort extraction of the last assistant message from a Claude Code
/// transcript (`transcript_path`, JSONL). Used only as a fallback when the Stop hook
/// didn't provide `last_assistant_message` directly.
///
/// The transcript format evolves, so this is intentionally forgiving: it scans lines
/// bottom-up and pulls text out of whatever assistant-shaped record it finds first.
enum TranscriptReader {
    static func lastAssistantMessage(path: String) -> String? {
        guard !path.isEmpty,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let lines = content.split(separator: "\n").map(String.init)
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if let text = assistantText(from: object), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Pulls assistant text out of a single transcript record, handling a couple of
    /// plausible shapes:
    ///   { "type": "assistant", "message": { "role": "assistant", "content": [...] } }
    ///   { "role": "assistant", "content": "..." | [...] }
    private static func assistantText(from object: [String: Any]) -> String? {
        // Unwrap a nested `message` if present.
        let record: [String: Any]
        if let message = object["message"] as? [String: Any] {
            record = message
        } else {
            record = object
        }

        let type = (object["type"] as? String) ?? (record["role"] as? String)
        guard type == "assistant" else { return nil }

        if let text = record["content"] as? String {
            return text
        }
        if let blocks = record["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }
}
