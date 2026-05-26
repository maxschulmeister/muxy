import Foundation

struct WorktreeConfig: Codable {
    struct SetupCommand: Codable {
        let command: String
        let name: String?

        init(command: String, name: String? = nil) {
            self.command = command
            self.name = name
        }
    }

    let setup: [SetupCommand]
    let teardown: [SetupCommand]

    private enum CodingKeys: String, CodingKey {
        case setup
        case teardown
    }

    init(setup: [SetupCommand], teardown: [SetupCommand] = []) {
        self.setup = setup
        self.teardown = teardown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        setup = Self.decodeCommands(from: container, forKey: .setup)
        teardown = Self.decodeCommands(from: container, forKey: .teardown)
    }

    private static func decodeCommands(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [SetupCommand] {
        if let objectEntries = try? container.decode([SetupCommand].self, forKey: key) {
            return objectEntries
        }
        if let stringEntries = try? container.decode([String].self, forKey: key) {
            return stringEntries.map { SetupCommand(command: $0) }
        }
        return []
    }

    static func load(fromProjectPath projectPath: String) -> WorktreeConfig? {
        let url = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".muxy")
            .appendingPathComponent("worktree.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorktreeConfig.self, from: data)
    }
}
