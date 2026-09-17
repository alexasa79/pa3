import Foundation

func runSelectedTextTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        if !condition { failures.append("selection: " + name) }
    }
    struct Node {
        var text: String? = nil
        var children: [Int] = []
    }
    func read(_ tree: [Int: Node], limit: Int = 300) throws -> String? {
        try SelectedText.collect(from: 0, nodeLimit: limit, isSame: ==) { id in
            guard let node = tree[id] else { throw SelectedText.ReadFailure.incomplete }
            return (node.text, node.children)
        }
    }
    func rejects(_ failure: SelectedText.ReadFailure, _ name: String, _ body: () throws -> String?) {
        switch Result(catching: body) {
        case .success: failures.append("selection: " + name)
        case .failure(let error): check(error as? SelectedText.ReadFailure == failure, name + " (wrong error)")
        }
    }
    do {
        // Apple article views expose each selected paragraph as a sibling AXStaticText.
        let paragraphs = (1...8).map { "Selected paragraph \($0)." }
        var article = [0: Node(children: Array(1...8))]
        for (index, paragraph) in paragraphs.enumerated() { article[index + 1] = Node(text: paragraph) }
        let text = try read(article)
        check(text == paragraphs.joined(separator: "\n\n"), "all eight selected paragraphs reach narration")
        let planned = try NarrationText.plan(NarrationInput(text: text ?? ""))
        check(planned.map(\.text) == paragraphs, "narration includes the last selected paragraph")
        check(planned.dropLast().allSatisfy { $0.pauseAfter == 0.65 }, "paragraph boundaries retain narration pauses")

        check(try read([
            0: Node(children: [1, 2]), 1: Node(children: [3]),
            2: Node(text: "Second."), 3: Node(text: "First.")
        ]) == "First.\n\nSecond.", "nested paragraphs remain in reading order")

        check(try read([
            0: Node(children: [1, 2]),
            1: Node(text: "First.\n\nSecond.", children: [3, 4]),
            2: Node(text: "Third."), 3: Node(text: "First."), 4: Node(text: "Second.")
        ]) == "First.\n\nSecond.\n\nThird.", "parent selection is not repeated by descendants")

        check(try read([
            0: Node(children: [1, 2]), 1: Node(text: "Again."), 2: Node(text: "Again.")
        ]) == "Again.\n\nAgain.", "identical paragraphs in different elements are preserved")

        check(try read([
            0: Node(children: [1, 2, 3]), 1: Node(text: "First."),
            2: Node(children: [0, 1, 4]), 3: Node(text: "Third."), 4: Node(text: "Second.")
        ]) == "First.\n\nSecond.\n\nThird.", "shared elements and cycles do not duplicate selection")

        check(try read([0: Node(children: [1, 2]), 1: Node(), 2: Node(text: " \n ")]) == nil,
              "empty selections do not narrate unselected content")
        check(try read([0: Node(children: [1, 2]), 1: Node(text: " \n "), 2: Node(text: "Selected.")]) == "Selected.",
              "whitespace-only selections add no empty paragraphs")

        check(try read([
            0: Node(children: [1, 2]),
            1: Node(text: SelectedText.substring("Before 🙂 first.", range: CFRange(location: 7, length: 9))),
            2: Node(text: SelectedText.substring("Last. After", range: CFRange(location: 0, length: 5)))
        ]) == "🙂 first.\n\nLast.", "partially selected edge paragraphs exclude unselected text")

        check(try read([0: Node(children: [1, 2]), 1: Node(text: "One."), 2: Node(text: "Two.")], limit: 3) == "One.\n\nTwo.",
              "a selection exactly at the traversal limit is complete")
        let withinLimit = try read([
            0: Node(children: [1, 2]), 1: Node(text: String(repeating: "a", count: 49_999)),
            2: Node(text: String(repeating: "b", count: 49_999))
        ])
        check(withinLimit?.count == 100_000, "combined character limit includes paragraph separators")
    } catch { failures.append("selection: unexpected read failure \(error)") }

    rejects(.incomplete, "node limit must not silently return the first paragraph") {
        try read([0: Node(children: [1, 2]), 1: Node(text: "One."), 2: Node(text: "Two.")], limit: 2)
    }
    rejects(.incomplete, "an inaccessible node must not silently truncate the selection") {
        try read([0: Node(children: [1, 2]), 1: Node(text: "One.")])
    }
    rejects(.tooLarge, "combined selection cannot exceed the character limit") {
        try read([
            0: Node(children: [1, 2]), 1: Node(text: String(repeating: "a", count: 50_000)),
            2: Node(text: String(repeating: "b", count: 50_000))
        ])
    }
    return failures
}
