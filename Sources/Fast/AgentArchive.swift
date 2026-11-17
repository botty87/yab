import Foundation

/// The provider's persisted archive flag for a background conversation Yab
/// created. Call only after its answer has been delivered and its process
/// has exited; this never discovers or archives unrelated conversations.
enum AgentArchive {
    /// Desktop discovers CLI transcripts by their first entrypoint, and
    /// takes one marked claude-desktop for its own. A caller can set that
    /// origin, so background work names Yab again here, as every Claude
    /// account does (PlanAccounts.entrypoint), whatever it was handed.
    static func environment(cli: String, background: Bool, base: [String: String]) -> [String: String] {
        guard cli == "claude", background else { return base }
        var env = base
        env["CLAUDE_CODE_ENTRYPOINT"] = PlanAccounts.entrypoint
        return env
    }

    /// Claude's Desktop record may not exist for a CLI conversation. In
    /// that case leave the transcript and the app's records alone. Existing
    /// records are matched by the CLI's id, never by their title or folder.
    /// The running Desktop app may keep a record in memory until it reloads.
    static func claude(thread: String, user: URL) throws -> Bool {
        guard !thread.isEmpty else { return false }
        let root = user.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        let manager = FileManager.default
        do {
            guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return false }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return false
        }
        let canonicalRoot = root.resolvingSymlinksInPath().path + "/"
        var scanFailure: Error?
        guard let files = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                            options: [.skipsHiddenFiles], errorHandler: { _, error in
            scanFailure = error
            return true
        }) else { return false }
        var changed = false
        for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  file.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) else { continue }
            let original = try Data(contentsOf: file)
            guard var record = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
                  record["cliSessionId"] as? String == thread,
                  record["isArchived"] as? Bool != true,
                  record["isRunning"] as? Bool != true,
                  record["starting"] as? Bool != true else { continue }
            record["isArchived"] = true
            let archived = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            // An app save during this scan belongs to it. Do not replace it
            // with a snapshot read before that save.
            guard try Data(contentsOf: file) == original else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Claude's session record changed while archiving."])
            }
            try archived.write(to: file, options: .atomic)
            changed = true
        }
        if let scanFailure { throw scanFailure }
        return changed
    }
}
