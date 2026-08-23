import Foundation

// Bot name generator — the port of server/names.ts. A curated local list
// beats a naming API: instant, offline, and every name is on-brand (short,
// friendly, a little pet-like). Picks avoid names already in use; when the
// pool is exhausted it falls back to "Name 2", "Name 3", …
public enum Names {
    public static let pool: [String] = [
        "Scout", "Pixel", "Atlas", "Nova", "Juno", "Koda", "Miso", "Mochi",
        "Biscuit", "Pepper", "Clover", "Ember", "Willow", "Comet", "Orbit", "Echo",
        "Indigo", "Sage", "Zephyr", "Poppy", "Maple", "Cosmo", "Luna", "Otto",
        "Ivy", "Finch", "Wren", "Basil", "Hazel", "Nimbus", "Onyx", "Pearl",
        "Quill", "Rocket", "Sunny", "Tango", "Vega", "Waffle", "Ziggy", "Noodle",
        "Pickle", "Churro", "Panko", "Dumpling", "Pesto", "Olive", "Cocoa", "Taffy",
        "Bramble", "Fig", "Juniper", "Moss", "Pebble", "Rio", "Skye", "Tuli",
        "Ursa", "Yuki", "Zuko", "Momo", "Kiwi", "Plum", "Sprout", "Turnip",
    ]

    private static func randomIndex(_ upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int.random(in: 0..<upperBound)
    }

    public static func pickBotName(taken: some Sequence<String>) -> String {
        let used = Set(taken.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let free = pool.filter { !used.contains($0.lowercased()) }
        if !free.isEmpty {
            return free[randomIndex(free.count)]
        }
        // pool exhausted — number a random base name
        let base = pool[randomIndex(pool.count)]
        var n = 2
        while used.contains("\(base.lowercased()) \(n)") {
            n += 1
        }
        return "\(base) \(n)"
    }
}
