import Testing
import Foundation
import SwiftData
@testable import NotchVoice

private func draft(
    text: String = "hello world",
    rawText: String? = nil,
    duration: Double = 3,
    bundleID: String? = "com.apple.dt.Xcode",
    appName: String? = "Xcode"
) -> CaptureDraft {
    CaptureDraft(
        text: text,
        rawText: rawText,
        durationSeconds: duration,
        language: "en",
        targetBundleID: bundleID,
        targetAppName: appName,
        micDevice: "MacBook Pro Microphone",
        modelVariant: "test-model"
    )
}

@Suite("CaptureStore")
struct CaptureStoreTests {

    private func store() throws -> CaptureStore {
        CaptureStore(modelContainer: try DataStack.inMemory().container)
    }

    @Test("a recorded dictation is there afterwards")
    func recordPersists() async throws {
        let store = try store()
        #expect(try await store.captureCount() == 0)
        try await store.record(draft())
        #expect(try await store.captureCount() == 1)
    }

    @Test("recording twice keeps both")
    func recordsAccumulate() async throws {
        let store = try store()
        try await store.record(draft(text: "first"))
        try await store.record(draft(text: "second"))
        #expect(try await store.captureCount() == 2)
    }

    @Test("totals add up across captures")
    func totalsAggregate() async throws {
        let store = try store()
        try await store.record(draft(text: "one two three", duration: 6))
        try await store.record(draft(text: "four five", duration: 4))

        let totals = try await store.totals()
        #expect(totals.captures == 2)
        #expect(totals.words == 5)
        #expect(totals.seconds == 10)
        // 5 words in 10s = 30wpm
        #expect(totals.wordsPerMinute == 30)
    }

    @Test("an empty store reports no speaking rate rather than zero")
    func totalsWithoutDataHaveNoRate() async throws {
        // Zero would render as "0 wpm", which is a claim about the user rather
        // than an absence of data.
        let totals = try await store().totals()
        #expect(totals.captures == 0)
        #expect(totals.wordsPerMinute == nil)
    }

    @Test("clearing history leaves the dictionary and snippets alone")
    func deleteCapturesKeepsSettings() async throws {
        let stack = try DataStack.inMemory()
        let store = CaptureStore(modelContainer: stack.container)
        try await store.record(draft())

        let context = ModelContext(stack.container)
        context.insert(DictionaryEntry(phrase: "Sukrit"))
        context.insert(Snippet(trigger: "sig", expansion: "Best, Sukrit"))
        try context.save()

        try await store.deleteAllCaptures()

        #expect(try await store.captureCount() == 0)
        // These are settings the user built up, not history.
        #expect(try context.fetchCount(FetchDescriptor<DictionaryEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Snippet>()) == 1)
    }

    @Test("applying a dictionary entry counts it")
    func dictionaryUseIsCounted() async throws {
        let stack = try DataStack.inMemory()
        let store = CaptureStore(modelContainer: stack.container)

        let context = ModelContext(stack.container)
        context.insert(DictionaryEntry(phrase: "Kubernetes", misheardAs: "cuber netties"))
        try context.save()

        try await store.noteDictionaryUse(phrase: "Kubernetes")
        try await store.noteDictionaryUse(phrase: "Kubernetes")

        let entries = try context.fetch(FetchDescriptor<DictionaryEntry>())
        #expect(entries.first?.timesApplied == 2)
    }

    @Test("counting a word that isn't in the dictionary is not an error")
    func unknownDictionaryUseIsIgnored() async throws {
        // The rewrite pass runs over every transcript; a phrase deleted between
        // transcription and counting must not throw away the dictation.
        try await store().noteDictionaryUse(phrase: "never added")
    }
}

@Suite("Capture")
struct CaptureTests {

    @Test("word count matches how a person would count",
          arguments: [
            ("hello world", 2),
            ("hello,  world", 2),          // double space
            ("one\ntwo\nthree", 3),        // newlines — the case split(" ") gets wrong
            ("one\ttwo", 2),               // tabs, likewise
            ("  padded  ", 1),
            ("", 0),
          ])
    func wordCount(_ input: String, _ expected: Int) {
        #expect(Capture.countWords(input) == expected)
    }

    @Test("a polished capture knows it was polished")
    func polishIsRecorded() {
        let polished = draft(text: "Hello, world.", rawText: "um hello world").model()
        #expect(polished.wasPolished)
        #expect(polished.rawText == "um hello world")

        let untouched = draft(text: "Hello, world.", rawText: nil).model()
        #expect(!untouched.wasPolished)
    }

    @Test("a take too short to time has no speaking rate")
    func shortTakesHaveNoRate() {
        // 3 words in 0.4s extrapolates to 450wpm, which is nonsense rather than
        // a fast talker.
        let brief = draft(text: "one two three", duration: 0.4).model()
        #expect(brief.wordsPerMinute == nil)

        let real = draft(text: "one two three", duration: 6).model()
        #expect(real.wordsPerMinute == 30)
    }
}
