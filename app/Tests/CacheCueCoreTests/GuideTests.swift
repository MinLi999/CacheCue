import XCTest

@testable import CacheCueCore

final class GuideTests: XCTestCase {
    func testEveryWrittenLanguageHasTheSameLessons() {
        let english = Guide.lessons(.en)
        XCTAssertEqual(english.map(\.id), [
            "context-cost", "cache-clock", "compact-cost", "best-moment", "compact-clear-rewind", "cache-breakers",
            "small-context", "reading-cachecue",
        ])
        for language in Guide.languages {
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
        // A wrong copy-paste would leave one language reading as another.
        XCTAssertNotEqual(Guide.lessons(.zhHans).map(\.title), english.map(\.title))
        XCTAssertNotEqual(Guide.lessons(.zhHant).map(\.title), Guide.lessons(.zhHans).map(\.title))
    }

    func testOtherLanguagesReadTheLessonsInEnglish() {
        for language in Language.allCases where !Guide.languages.contains(language) {
            XCTAssertEqual(Guide.lessons(language), Guide.lessons(.en), language.rawValue)
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
