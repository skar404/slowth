import Foundation

@main
struct ShieldNavigationBindingsTests {
    static func main() {
        let suite = "test.shield.navigation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = Data("system-token".utf8)
        let secondToken = Data("new-system-token".utf8)
        let selection = Data("picker-token".utf8)
        let bindings = ["youtube": selection, "instagram": Data("instagram".utf8)]
        let choice = ShieldNavigationBindings.Choice(token: token, selections: bindings)
        func resolve(_ bindings: [String: Data], token: Data = token) -> String? {
            ShieldNavigationBindings.target(for: token, selections: bindings, defaults: defaults)
        }
        // First unknown handoff asks; confirming it survives a new defaults instance.
        assert(resolve(bindings) == nil)
        ShieldNavigationBindings.confirm(choice, target: "youtube", selections: bindings, defaults: defaults)
        assert(ShieldNavigationBindings.target(for: token, selections: bindings,
            defaults: UserDefaults(suiteName: suite)!) == "youtube")
        assert(resolve(bindings, token: secondToken) == nil)
        assert(resolve(["instagram": bindings["instagram"]!]) == nil)
        var changed = bindings
        changed["youtube"] = Data("replacement".utf8)
        assert(resolve(changed) == nil)
        // A picker change while the choice sheet was open cannot confirm stale data.
        ShieldNavigationBindings.confirm(choice, target: "youtube", selections: changed, defaults: defaults)
        assert(resolve(changed) == nil)
        ShieldNavigationBindings.invalidate("youtube", defaults: defaults)
        assert(resolve(bindings) == nil) // Even if an old picker selection returns later.
        ShieldNavigationBindings.confirm(choice, target: "missing", selections: bindings, defaults: defaults)
        assert(resolve(bindings) == nil)
        ShieldNavigationBindings.confirm(choice, target: "youtube", selections: bindings, defaults: defaults)
        ShieldNavigationBindings.confirm(choice, target: "instagram", selections: bindings, defaults: defaults)
        assert(resolve(bindings) == "instagram") // Latest explicit confirmation wins.
        ShieldNavigationBindings.invalidate("youtube", defaults: defaults)
        assert(resolve(bindings) == "instagram")
        print("Shield navigation binding tests passed")
    }
}
