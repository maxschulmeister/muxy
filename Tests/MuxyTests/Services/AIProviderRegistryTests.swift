import Testing

@testable import Muxy

@Suite("AIProviderRegistry notifications")
@MainActor
struct AIProviderRegistryTests {
    private let registry = AIProviderRegistry.shared

    @Test("displayName for pi socket type returns Pi")
    func displayNameForPiSocketType() {
        #expect(registry.displayName(forSocketType: "pi") == "Pi")
    }

    @Test("displayName for claude_hook socket type returns Claude Code")
    func displayNameForClaudeSocketType() {
        #expect(registry.displayName(forSocketType: "claude_hook") == "Claude Code")
    }

    @Test("displayName for unknown socket type returns nil")
    func displayNameForUnknownSocketType() {
        #expect(registry.displayName(forSocketType: "custom") == nil)
    }

    @Test("notificationSource for pi maps to aiProvider pi")
    func notificationSourceForPi() {
        #expect(registry.notificationSource(for: "pi") == .aiProvider("pi"))
    }

    @Test("displayName for aiProvider source returns provider display name")
    func displayNameForAIProviderSource() {
        #expect(registry.displayName(for: .aiProvider("pi")) == "Pi")
        #expect(registry.displayName(for: .aiProvider("claude")) == "Claude Code")
    }

    @Test("displayName for osc and socket sources returns nil")
    func displayNameForNonAIProviderSources() {
        #expect(registry.displayName(for: .osc) == nil)
        #expect(registry.displayName(for: .socket) == nil)
    }
}
