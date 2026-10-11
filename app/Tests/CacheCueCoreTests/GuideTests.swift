import XCTest

@testable import CacheCueCore

final class GuideTests: XCTestCase {
    func testEveryLanguageHasTheSameLessons() {
        let english = Guide.lessons(.en)
        XCTAssertEqual(english.map(\.id), [
            "context-cost", "cache-clock", "compact-cost", "best-moment", "compact-clear-rewind", "cache-breakers",
            "small-context", "reading-cachecue",
        ])
        for language in Language.allCases {
            let lessons = Guide.lessons(language)
            XCTAssertEqual(lessons.map(\.id), english.map(\.id), language.rawValue)
            for (lesson, reference) in zip(lessons, english) {
                // The same points in the same order, so a lesson says the same thing everywhere.
                XCTAssertEqual(lesson.points.count, reference.points.count, "\(language.rawValue) \(lesson.id)")
                XCTAssertEqual(lesson.source, reference.source)
                for text in [lesson.title, lesson.summary, lesson.takeaway] + lesson.points {
                    XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue) \(lesson.id)")
                }
            }
        }
    }

    func testTheLessonsAreInTheLanguageOfTheInterface() {
        // No language reads another's lessons: a wrong copy-paste, or a fall back to English,
        // would show up as two languages sharing a title, a summary or a takeaway.
        for field in [\Lesson.title, \Lesson.summary, \Lesson.takeaway] {
            for index in Guide.lessons(.en).indices {
                // Lesson 5's title is three commands and one word, which a few languages share.
                if field == \Lesson.title && Guide.lessons(.en)[index].id == "compact-clear-rewind" { continue }
                var seen: [String: Language] = [:]
                for language in Language.allCases {
                    let text = Guide.lessons(language)[index][keyPath: field]
                    if let other = seen[text] {
                        // Simplified and Traditional Chinese may write a short line identically.
                        XCTAssertEqual(
                            [other, language], [.zhHans, .zhHant],
                            "lesson \(index + 1): \(other.rawValue) and \(language.rawValue) share “\(text)”")
                    }
                    seen[text] = language
                }
            }
        }
    }

    func testEveryLanguageKeepsTheCommandsAndFiguresIntact() {
        func all(_ lesson: Lesson) -> String { ([lesson.title, lesson.summary, lesson.takeaway] + lesson.points).joined(separator: " ") }
        for language in Language.allCases {
            let lessons = Dictionary(uniqueKeysWithValues: Guide.lessons(language).map { ($0.id, all($0)) })
            let name = language.rawValue
            // What the person types is never translated.
            for command in ["/clear", "/compact", "/rewind", "/rename", "/resume"] {
                XCTAssertTrue(lessons["compact-clear-rewind"]!.contains(command), "\(name) \(command)")
            }
            for term in ["/model", "opusplan", "effort", "fast mode", "/recap", "claude.md"] {
                // A term may open a sentence, so its case is not held against it.
                XCTAssertTrue(lessons["cache-breakers"]!.lowercased().contains(term), "\(name) \(term)")
            }
            for term in ["auth.ts", "CLAUDE.md", "200", "MCP", "/context"] {
                XCTAssertTrue(lessons["small-context"]!.contains(term), "\(name) \(term)")
            }
            for term in ["5h", "7d", "70", "90", "live", "exp", "/compact"] {
                XCTAssertTrue(lessons["reading-cachecue"]!.contains(term), "\(name) \(term)")
            }
            // The figures the lessons rest on.
            XCTAssertTrue(lessons["cache-clock"]!.contains("20"), name)
            XCTAssertTrue(lessons["best-moment"]!.contains("/compact"), name)
            let large = lessons["best-moment"]!
            XCTAssertTrue(
                ["100k", "10 万", "10 萬"].contains { large.contains($0) }, "\(name): the 100k rule of thumb")
            // No stray ASCII quote that would have ended a Swift string early and still compiled.
            XCTAssertFalse(lessons.values.contains { $0.contains("\\") }, name)
        }
    }

    func testEveryPieceOfAdviceLeadsToALessonThatExists() {
        let ids = Set(Guide.lessons(.en).map(\.id))
        let kinds: [CompactAdvice.Kind] = [.nearFull, .notNeeded, .cold, .beforeExpiry, .worthIt, .optional]
        for kind in kinds {
            let id = Guide.lessonID(for: kind)
            XCTAssertNotNil(id, "\(kind)")
            XCTAssertTrue(ids.contains(id ?? ""), "\(kind) -> \(id ?? "nil")")
        }
        XCTAssertNil(Guide.lessonID(for: .running))
    }

    func testTheGuideQuotesTheSameThresholdsAsTheRules() {
        // The lessons state the rules of thumb in words; they must not drift from the code.
        XCTAssertEqual(CompactAdvice.largeContext, 100_000)
        XCTAssertTrue(Guide.lessons(.en).first { $0.id == "best-moment" }!.points.joined().contains("100k tokens"))
        XCTAssertTrue(Guide.lessons(.zhHans).first { $0.id == "best-moment" }!.points.joined().contains("10 万 token"))
        XCTAssertTrue(Guide.lessons(.en).first { $0.id == "reading-cachecue" }!.points.joined().contains("70% and red at 90%"))
    }
}
