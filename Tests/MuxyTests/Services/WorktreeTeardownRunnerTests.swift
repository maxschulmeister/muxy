import Foundation
import Testing

@testable import Muxy

@Suite("WorktreeTeardownRunner")
struct WorktreeTeardownRunnerTests {
    @Test("WorktreeConfig decodes teardown strings and objects")
    func configDecodesTeardownCommands() throws {
        let json = """
        {
          "setup": ["pnpm install"],
          "teardown": [
            "docker compose down",
            { "name": "cleanup", "command": "rm -rf tmp" }
          ]
        }
        """

        let config = try JSONDecoder().decode(WorktreeConfig.self, from: Data(json.utf8))

        #expect(config.setup.map(\.command) == ["pnpm install"])
        #expect(config.teardown.map(\.command) == ["docker compose down", "rm -rf tmp"])
        #expect(config.teardown[1].name == "cleanup")
    }

    @Test("run executes teardown commands with worktree environment")
    func runExecutesTeardownCommandsWithEnvironment() async throws {
        let projectPath = try makeProjectConfig(teardown: [" first ", "", "second"])
        let worktree = Worktree(
            name: "Feature",
            path: "/tmp/feature",
            branch: "feature/test",
            source: .muxy,
            isPrimary: false
        )
        final class Capture: @unchecked Sendable {
            var commands: [String] = []
            var environments: [[String: String]] = []
        }
        let capture = Capture()

        try await WorktreeTeardownRunner.run(sourceProjectPath: projectPath, worktree: worktree) { command, _, environment in
            capture.commands.append(command)
            capture.environments.append(environment)
            return GitProcessResult(status: 0, stdout: "", stdoutData: Data(), stderr: "", truncated: false)
        }

        #expect(capture.commands == ["first", "second"])
        #expect(capture.environments.allSatisfy { $0["MUXY_WORKTREE_PATH"] == "/tmp/feature" })
        #expect(capture.environments.allSatisfy { $0["MUXY_WORKTREE_NAME"] == "Feature" })
        #expect(capture.environments.allSatisfy { $0["MUXY_WORKTREE_BRANCH"] == "feature/test" })
    }

    @Test("run skips externally managed worktrees")
    func runSkipsExternalWorktrees() async throws {
        let projectPath = try makeProjectConfig(teardown: ["cleanup"])
        let worktree = Worktree(
            name: "External",
            path: "/tmp/external",
            branch: "external",
            source: .external,
            isPrimary: false
        )
        final class Capture: @unchecked Sendable {
            var count = 0
        }
        let capture = Capture()

        try await WorktreeTeardownRunner.run(sourceProjectPath: projectPath, worktree: worktree) { _, _, _ in
            capture.count += 1
            return GitProcessResult(status: 0, stdout: "", stdoutData: Data(), stderr: "", truncated: false)
        }

        #expect(capture.count == 0)
    }

    @Test("run stops and throws on teardown failure")
    func runStopsOnFailure() async throws {
        let projectPath = try makeProjectConfig(teardown: ["fail", "after"])
        let worktree = Worktree(name: "Feature", path: "/tmp/feature", branch: nil, source: .muxy, isPrimary: false)
        final class Capture: @unchecked Sendable {
            var commands: [String] = []
        }
        let capture = Capture()

        await #expect(throws: WorktreeTeardownError.self) {
            try await WorktreeTeardownRunner.run(sourceProjectPath: projectPath, worktree: worktree) { command, _, _ in
                capture.commands.append(command)
                return GitProcessResult(status: 1, stdout: "", stdoutData: Data(), stderr: "boom", truncated: false)
            }
        }
        #expect(capture.commands == ["fail"])
    }

    private func makeProjectConfig(teardown: [String]) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muxy-teardown-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".muxy", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(WorktreeConfig(
            setup: [],
            teardown: teardown.map { WorktreeConfig.SetupCommand(command: $0) }
        ))
        try data.write(to: configDirectory.appendingPathComponent("worktree.json"))
        return root.path
    }
}
