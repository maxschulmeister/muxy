import Foundation

enum WorktreeTeardownError: LocalizedError {
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Teardown command failed: \(command)"
            }
            return "Teardown command failed: \(command)\n\n\(trimmed)"
        }
    }
}

enum WorktreeTeardownRunner {
    typealias Executor = @Sendable (_ command: String, _ worktree: Worktree, _ environment: [String: String]) async throws -> GitProcessResult

    static func run(
        sourceProjectPath: String,
        worktree: Worktree,
        executor: Executor = execute
    ) async throws {
        guard !worktree.isExternallyManaged,
              let config = WorktreeConfig.load(fromProjectPath: sourceProjectPath)
        else { return }

        for command in config.teardown.map(\.command) {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let result = try await executor(trimmed, worktree, environment(for: worktree))
            guard result.status == 0 else {
                throw WorktreeTeardownError.commandFailed(
                    command: trimmed,
                    output: result.stderr.isEmpty ? result.stdout : result.stderr
                )
            }
        }
    }

    private static func execute(
        command: String,
        worktree: Worktree,
        environment: [String: String]
    ) async throws -> GitProcessResult {
        try await GitProcessRunner.runCommand(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            workingDirectory: worktree.path,
            environment: environment
        )
    }

    private static func environment(for worktree: Worktree) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MUXY_WORKTREE_PATH"] = worktree.path
        environment["MUXY_WORKTREE_NAME"] = worktree.name
        environment["MUXY_WORKTREE_BRANCH"] = worktree.branch ?? ""
        return environment
    }
}
