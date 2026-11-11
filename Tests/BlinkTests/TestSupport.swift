import Foundation
@testable import Blink

/// A fresh folder per test, deleted afterwards.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blink-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func tempPins() -> Pins { Pins(url: makeTempDir().appendingPathComponent("pins.json")) }
func tempUsage() -> Usage { Usage(url: makeTempDir().appendingPathComponent("usage.json")) }

/// A provider with fixed results, optionally slow, counting how often it's asked.
final class FakeProvider: Provider {
    let name: String
    let keyword: String?
    let isAsync: Bool
    let expandsOnPrefix: Bool
    var delay: TimeInterval
    var results: (String) -> [Item]
    var favoritesResult: ([String]) -> [Item] = { _ in [] }
    private(set) var calls: [String] = []
    private let lock = NSLock()

    init(name: String, keyword: String? = nil, isAsync: Bool = false, expandsOnPrefix: Bool = false,
         delay: TimeInterval = 0, results: @escaping (String) -> [Item]) {
        self.name = name
        self.keyword = keyword
        self.isAsync = isAsync
        self.expandsOnPrefix = expandsOnPrefix
        self.delay = delay
        self.results = results
    }

    func search(_ query: String) -> [Item] {
        lock.lock()
        calls.append(query)
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return results(query)
    }

    func favorites(_ ids: [String]) -> [Item] { favoritesResult(ids) }
}

func item(_ id: String, _ title: String, score: Int = 100) -> Item {
    Item(id: id, title: title, score: score, action: .none)
}
