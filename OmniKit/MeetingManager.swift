//
//  MeetingManager.swift
//  OmniKit
//
//  Created by Codex on 2026/4/14.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import NaturalLanguage
import Speech

private let speechRecognitionTargetRMS: Float = 0.12
private let speechRecognitionMaximumGain: Float = 8.0
private let speechRecognitionNoiseFloor: Float = 0.002
private let secondaryRecognitionFallbackDelay: TimeInterval = 3.5
private let primaryRecognitionHoldInterval: TimeInterval = 1.2

enum RecognitionLanguageOption: String, CaseIterable, Identifiable, Codable {
    case chinese = "zh-CN"
    case english = "en-US"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case french = "fr-FR"
    case german = "de-DE"
    case spanish = "es-ES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chinese:
            return "中文"
        case .english:
            return "English"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .spanish:
            return "Español"
        }
    }

    var languageCode: String {
        rawValue.components(separatedBy: CharacterSet(charactersIn: "-_")).first?.lowercased() ?? rawValue.lowercased()
    }

    var prioritizedLocaleIdentifiers: [String] {
        switch self {
        case .chinese:
            return ["zh-CN", "zh-Hans", "zh-SG", "zh-HK", "zh-TW"]
        case .english:
            return ["en-US", "en-GB", "en-AU", "en-IN"]
        case .japanese:
            return ["ja-JP"]
        case .korean:
            return ["ko-KR"]
        case .french:
            return ["fr-FR", "fr-CA"]
        case .german:
            return ["de-DE", "de-AT", "de-CH"]
        case .spanish:
            return ["es-ES", "es-MX", "es-US"]
        }
    }
}

private struct TranscriptStats {
    var chineseCount = 0
    var latinCount = 0
    var digitCount = 0
    var kanaCount = 0
    var hangulCount = 0
}

private struct RecognitionCandidateAnalysis {
    let candidate: RecognitionCandidate
    let recognizerLanguageCode: String
    let dominantLanguageCode: String?
    let stats: TranscriptStats
}

struct MeetingRecord: Identifiable, Equatable, Codable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var customTitle: String?
    var transcript: String
    var summary: String?
    var summaryProvider: String?
    var summaryModel: String?
    var summaryUpdatedAt: Date?
    var audioFileURL: URL?

    var title: String {
        if let customTitle,
           !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customTitle
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "会议录音 \(formatter.string(from: startedAt))"
    }
}

private struct RecognitionCandidate {
    let locale: Locale
    var text: String = ""
    var segmentCount: Int = 0
    var isFinal = false
    var updatedAt = Date.distantPast
}

private struct DeepSeekSummaryService {
    struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let stream: Bool
    }

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct ResponseBody: Decodable {
        let choices: [Choice]
        let error: APIError?
    }

    struct Choice: Decodable {
        let message: Message
    }

    struct APIError: Decodable {
        let message: String
    }

    func summarize(transcript: String, apiKey: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                messages: [
                    Message(
                        role: "system",
                        content: """
                        你是一个专业会议纪要助手。请只基于用户提供的会议转写内容生成中文摘要，不要编造未出现的信息。
                        输出结构固定为：
                        摘要
                        - ...

                        重点
                        - ...

                        待办/决策
                        - ...
                        如果没有明确待办或决策，写“未识别到明确的待办或决策。”
                        """
                    ),
                    Message(role: "user", content: transcript)
                ],
                temperature: 0.2,
                stream: false
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            if let errorBody = try? JSONDecoder().decode(ResponseBody.self, from: data),
               let message = errorBody.error?.message {
                throw NSError(domain: "DeepSeek", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "DeepSeek", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "DeepSeek 请求失败（HTTP \(httpResponse.statusCode)）"])
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw NSError(domain: "DeepSeek", code: -1, userInfo: [NSLocalizedDescriptionKey: "DeepSeek 返回了空摘要"])
        }
        return content
    }
}

@MainActor
final class MeetingManager: NSObject, ObservableObject, AVAudioPlayerDelegate, SFSpeechRecognizerDelegate {
    @Published var records: [MeetingRecord] = []
    @Published var isRecording = false
    @Published var statusMessage = "准备就绪"
    @Published var playingRecordID: MeetingRecord.ID?
    @Published var isPlaybackPaused = false
    @Published private(set) var summarizingRecordIDs: Set<MeetingRecord.ID> = []
    @Published private(set) var summaryErrors: [MeetingRecord.ID: String] = [:]
    @Published var deepSeekAPIKey: String {
        didSet {
            OmniKitStore.shared.set(deepSeekAPIKey, forKey: Self.deepSeekAPIKeyDefaultsKey)
        }
    }
    @Published var deepSeekModel: String {
        didSet {
            OmniKitStore.shared.set(deepSeekModel, forKey: Self.deepSeekModelDefaultsKey)
        }
    }
    @Published private(set) var primaryRecognitionLanguage: RecognitionLanguageOption
    @Published private(set) var secondaryRecognitionLanguage: RecognitionLanguageOption

    private let audioEngine = AVAudioEngine()
    private var speechRecognizers: [String: SFSpeechRecognizer] = [:]
    private var recognitionRequests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var recognitionTasks: [String: SFSpeechRecognitionTask] = [:]
    private var recognitionCandidates: [String: RecognitionCandidate] = [:]
    private var recognitionLocaleOrder: [String] = []
    private var lockedTranscriptLanguageCode: String?
    private var recognitionSessionStartedAt: Date?
    private var displayedTranscriptLocaleIdentifier: String?
    private var activeRecordID: MeetingRecord.ID?
    private var recordingAudioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private let fileManager = FileManager.default
    private static let primaryRecognitionLanguageDefaultsKey = "meeting.recognition.language.primary"
    private static let secondaryRecognitionLanguageDefaultsKey = "meeting.recognition.language.secondary"
    private static let deepSeekAPIKeyDefaultsKey = "meeting.summary.deepseek.apiKey"
    private static let deepSeekModelDefaultsKey = "meeting.summary.deepseek.model"
    private static let deepSeekSummaryProvider = "deepseek"
    static let defaultDeepSeekModel = "deepseek-v4-pro"

    override init() {
        let storedPrimary = Self.loadRecognitionLanguage(key: Self.primaryRecognitionLanguageDefaultsKey) ?? .chinese
        let storedSecondary = Self.loadRecognitionLanguage(key: Self.secondaryRecognitionLanguageDefaultsKey) ?? .english
        let normalizedLanguages = Self.normalizedRecognitionLanguages(primary: storedPrimary, secondary: storedSecondary)
        deepSeekAPIKey = OmniKitStore.shared.string(forKey: Self.deepSeekAPIKeyDefaultsKey) ?? ""
        deepSeekModel = OmniKitStore.shared.string(forKey: Self.deepSeekModelDefaultsKey) ?? Self.defaultDeepSeekModel
        primaryRecognitionLanguage = normalizedLanguages.primary
        secondaryRecognitionLanguage = normalizedLanguages.secondary
        super.init()
        loadRecords()
    }

    func startRecording() {
        guard !isRecording else { return }

        requestAuthorizationAndStart()
    }

    func stopRecording() {
        guard isRecording else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        endRecognitionSession()
        recordingAudioFile = nil
        isRecording = false
        statusMessage = "录音已结束"

        if let activeRecordID,
           let index = records.firstIndex(where: { $0.id == activeRecordID }) {
            records[index].endedAt = Date()
            if records[index].transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                records[index].transcript = "（无可用转写内容）"
            }
        }

        activeRecordID = nil
        saveRecords()
    }

    func record(for id: MeetingRecord.ID) -> MeetingRecord? {
        records.first(where: { $0.id == id })
    }

    func deleteRecord(_ id: MeetingRecord.ID) {
        if activeRecordID == id {
            stopRecording()
        }
        if let url = record(for: id)?.audioFileURL {
            try? fileManager.removeItem(at: url)
        }
        records.removeAll { $0.id == id }
        saveRecords()
    }

    func renameRecord(_ id: MeetingRecord.ID, to newTitle: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        records[index].customTitle = trimmed.isEmpty ? nil : trimmed
        saveRecords()
    }

    func isGeneratingSummary(for id: MeetingRecord.ID) -> Bool {
        summarizingRecordIDs.contains(id)
    }

    func summaryError(for id: MeetingRecord.ID) -> String? {
        summaryErrors[id]
    }

    func generateSummaryIfNeeded(for id: MeetingRecord.ID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let summary = records[index].summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty,
           records[index].summaryProvider == Self.deepSeekSummaryProvider,
           records[index].summaryModel == activeDeepSeekModel {
            return
        }
        await generateSummary(for: id)
    }

    func regenerateSummary(for id: MeetingRecord.ID) async {
        await generateSummary(for: id)
    }

    private func generateSummary(for id: MeetingRecord.ID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard !summarizingRecordIDs.contains(id) else { return }

        let transcript = records[index].transcript
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty,
              trimmedTranscript != "（无可用转写内容）" else {
            records[index].summary = "暂无可总结内容。"
            saveRecords()
            return
        }

        let apiKey = deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            summaryErrors[id] = "请先配置 DeepSeek API Key。"
            statusMessage = "请先配置 DeepSeek API Key。"
            return
        }

        let model = activeDeepSeekModel
        summarizingRecordIDs.insert(id)
        summaryErrors[id] = nil
        statusMessage = "正在通过 DeepSeek 生成会议摘要..."

        do {
            let summary = try await DeepSeekSummaryService().summarize(
                transcript: trimmedTranscript,
                apiKey: apiKey,
                model: model
            )
            if let updatedIndex = records.firstIndex(where: { $0.id == id }) {
                records[updatedIndex].summary = summary
                records[updatedIndex].summaryProvider = Self.deepSeekSummaryProvider
                records[updatedIndex].summaryModel = model
                records[updatedIndex].summaryUpdatedAt = Date()
                saveRecords()
                statusMessage = "DeepSeek 会议摘要已生成"
            }
        } catch {
            let message = "DeepSeek 摘要生成失败：\(error.localizedDescription)"
            summaryErrors[id] = message
            statusMessage = message
        }
        summarizingRecordIDs.remove(id)
    }

    private var activeDeepSeekModel: String {
        let trimmed = deepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultDeepSeekModel : trimmed
    }

    func playRecord(_ id: MeetingRecord.ID) {
        guard let record = record(for: id),
              let url = record.audioFileURL else {
            statusMessage = "该录音暂无可播放音频。"
            return
        }
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 1024 else {
            statusMessage = "录音文件无有效声音数据，请重新录音。"
            return
        }

        // 同一条录音：播放 <-> 暂停 切换
        if playingRecordID == id, let audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                isPlaybackPaused = true
                statusMessage = "已暂停：\(record.title)"
            } else {
                audioPlayer.play()
                isPlaybackPaused = false
                statusMessage = "继续播放：\(record.title)"
            }
            return
        }

        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            playingRecordID = id
            isPlaybackPaused = false
            statusMessage = "正在播放：\(record.title)"
        } catch {
            playingRecordID = nil
            isPlaybackPaused = false
            statusMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(meetingsDirectoryURL())
    }

    func setPrimaryRecognitionLanguage(_ language: RecognitionLanguageOption) {
        let previousPrimary = primaryRecognitionLanguage
        let previousSecondary = secondaryRecognitionLanguage

        let resolvedSecondary: RecognitionLanguageOption
        if previousSecondary == language {
            resolvedSecondary = previousPrimary == language
                ? Self.fallbackRecognitionLanguage(excluding: language)
                : previousPrimary
        } else {
            resolvedSecondary = previousSecondary
        }

        let normalized = Self.normalizedRecognitionLanguages(primary: language, secondary: resolvedSecondary)
        primaryRecognitionLanguage = normalized.primary
        secondaryRecognitionLanguage = normalized.secondary
        persistRecognitionLanguages()
    }

    func setSecondaryRecognitionLanguage(_ language: RecognitionLanguageOption) {
        let normalized = Self.normalizedRecognitionLanguages(primary: primaryRecognitionLanguage, secondary: language)
        primaryRecognitionLanguage = normalized.primary
        secondaryRecognitionLanguage = normalized.secondary
        persistRecognitionLanguages()
    }

    private func requestAuthorizationAndStart() {
        statusMessage = "请求权限中..."
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            Task { @MainActor in
                guard speechStatus == .authorized else {
                    self.statusMessage = "语音识别权限被拒绝，请在系统设置中允许。"
                    return
                }

                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.statusMessage = "麦克风权限被拒绝，请在系统设置中允许。"
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    private func beginRecognition() {
        let recognizers = preferredSpeechRecognizers()
        guard !recognizers.isEmpty else {
            statusMessage = "当前系统没有可用的语音识别语言。"
            return
        }

        let audioURL = makeAudioURL()
        let newRecord = MeetingRecord(
            id: UUID(),
            startedAt: Date(),
            endedAt: nil,
            customTitle: nil,
            transcript: "",
            summary: nil,
            summaryProvider: nil,
            summaryModel: nil,
            summaryUpdatedAt: nil,
            audioFileURL: audioURL
        )
        records.insert(newRecord, at: 0)
        activeRecordID = newRecord.id
        saveRecords()

        endRecognitionSession()
        audioPlayer?.stop()
        playingRecordID = nil
        isPlaybackPaused = false

        speechRecognizers = Dictionary(
            uniqueKeysWithValues: recognizers.map { ($0.locale.identifier, $0) }
        )
        recognitionLocaleOrder = recognizers.map(\.locale.identifier)
        lockedTranscriptLanguageCode = nil
        recognitionSessionStartedAt = Date()
        displayedTranscriptLocaleIdentifier = nil

        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.defaultTaskHint = .dictation

            let localeIdentifier = recognizer.locale.identifier
            recognitionCandidates[localeIdentifier] = RecognitionCandidate(locale: recognizer.locale)
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard !format.settings.isEmpty,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            statusMessage = "无法获取录音格式，录音启动失败。"
            endRecognitionSession()
            records.removeAll { $0.id == newRecord.id }
            activeRecordID = nil
            saveRecords()
            return
        }

        do {
            recordingAudioFile = try AVAudioFile(
                forWriting: audioURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            statusMessage = "无法创建录音文件：\(error.localizedDescription)"
            endRecognitionSession()
            records.removeAll { $0.id == newRecord.id }
            activeRecordID = nil
            saveRecords()
            return
        }

        guard let audioFile = recordingAudioFile else {
            statusMessage = "录音写入初始化失败。"
            endRecognitionSession()
            records.removeAll { $0.id == newRecord.id }
            activeRecordID = nil
            saveRecords()
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let recognitionBuffer = boostedRecognitionBuffer(from: buffer) ?? buffer

            if let self {
                for localeIdentifier in self.recognitionTasks.keys {
                    guard let request = self.recognitionRequests[localeIdentifier] else { continue }
                    request.append(recognitionBuffer)
                }
            }

            do {
                try audioFile.write(from: buffer)
            } catch {
                Task { @MainActor in
                    self?.statusMessage = "写入录音失败：\(error.localizedDescription)"
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusMessage = "无法启动录音：\(error.localizedDescription)"
            endRecognitionSession()
            recordingAudioFile = nil
            records.removeAll { $0.id == newRecord.id }
            activeRecordID = nil
            saveRecords()
            return
        }

        isRecording = true
        for recognizer in recognizers {
            startRecognitionTaskIfPossible(for: recognizer)
        }
        updateRecordingStatusMessage()
    }

    private func preferredSpeechRecognizers() -> [SFSpeechRecognizer] {
        let supportedLocales = Array(SFSpeechRecognizer.supportedLocales())
        guard !supportedLocales.isEmpty else { return [] }

        var selected: [Locale] = []
        var seen = Set<String>()

        func appendLocale(_ locale: Locale) {
            let normalizedIdentifier = normalizedLocaleIdentifier(locale)
            guard seen.insert(normalizedIdentifier).inserted else { return }
            selected.append(locale)
        }

        for language in [primaryRecognitionLanguage, secondaryRecognitionLanguage] {
            for locale in preferredLocales(
                from: supportedLocales,
                option: language,
                limit: 1
            ) {
                appendLocale(locale)
            }
        }

        if selected.isEmpty,
           let fallbackLocale = supportedLocales.sorted(by: {
               normalizedLocaleIdentifier($0) < normalizedLocaleIdentifier($1)
           }).first {
            appendLocale(fallbackLocale)
        }

        return selected.compactMap(SFSpeechRecognizer.init(locale:))
    }

    private func preferredLocales(
        from supportedLocales: [Locale],
        option: RecognitionLanguageOption,
        limit: Int
    ) -> [Locale] {
        preferredLocales(
            from: supportedLocales,
            matching: option.languageCode,
            prioritizedIdentifiers: option.prioritizedLocaleIdentifiers,
            limit: limit
        )
    }

    private func preferredLocales(
        from supportedLocales: [Locale],
        matching languageCode: String,
        prioritizedIdentifiers: [String],
        limit: Int
    ) -> [Locale] {
        guard limit > 0 else { return [] }

        let normalizedSupported = supportedLocales.sorted {
            normalizedLocaleIdentifier($0) < normalizedLocaleIdentifier($1)
        }
        let normalizedPriorities = prioritizedIdentifiers.map(normalizedLocaleIdentifier(_:))
        var selected: [Locale] = []
        var seen = Set<String>()

        func append(_ locale: Locale) {
            let identifier = normalizedLocaleIdentifier(locale)
            guard seen.insert(identifier).inserted else { return }
            selected.append(locale)
        }

        for priority in normalizedPriorities {
            if let exactMatch = normalizedSupported.first(where: {
                normalizedLocaleIdentifier($0) == priority
            }) {
                append(exactMatch)
                if selected.count == limit { return selected }
            }
        }

        for priority in normalizedPriorities {
            if let prefixMatch = normalizedSupported.first(where: {
                let identifier = normalizedLocaleIdentifier($0)
                return identifier.hasPrefix(priority + "-")
            }) {
                append(prefixMatch)
                if selected.count == limit { return selected }
            }
        }

        for locale in normalizedSupported where locale.language.languageCode?.identifier == languageCode {
            append(locale)
            if selected.count == limit { return selected }
        }

        return selected
    }

    private func normalizedLocaleIdentifier(_ locale: Locale) -> String {
        normalizedLocaleIdentifier(locale.identifier)
    }

    private func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func recognitionLanguageSummary() -> String {
        [primaryRecognitionLanguage.title, secondaryRecognitionLanguage.title].joined(separator: " + ")
    }

    private func activeRecognitionLanguageSummary(from recognizers: [SFSpeechRecognizer]) -> String {
        let activeTitles = recognizers.map { displayName(for: $0.locale) }
        return activeTitles.isEmpty ? recognitionLanguageSummary() : activeTitles.joined(separator: " + ")
    }

    private func isRecognitionLanguageAvailable(_ languageCode: String, in recognizers: [SFSpeechRecognizer]) -> Bool {
        recognizers.contains { $0.isAvailable && localeLanguageCode($0.locale) == languageCode }
    }

    private func hasActiveRecognitionTask(for languageCode: String) -> Bool {
        recognitionTasks.keys.contains { localeIdentifier in
            normalizedLanguageCode(from: localeIdentifier) == languageCode
        }
    }

    private func startRecognitionTaskIfPossible(for recognizer: SFSpeechRecognizer) {
        let locale = recognizer.locale
        let localeIdentifier = locale.identifier
        guard recognizer.isAvailable else { return }
        guard recognitionTasks[localeIdentifier] == nil else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = contextualStrings(for: recognizer.locale)
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        recognitionRequests[localeIdentifier] = request
        recognitionTasks[localeIdentifier] = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.updateRecognitionCandidate(locale: locale, result: result)
                }

                if let error {
                    self.handleRecognitionError(error, locale: locale)
                }
            }
        }
    }

    private func updateRecordingStatusMessage(displaying candidate: RecognitionCandidate? = nil) {
        guard isRecording else { return }

        if let candidate {
            let sourceName = displayName(for: candidate.locale)
            if localeLanguageCode(candidate.locale) == primaryRecognitionLanguage.languageCode {
                statusMessage = "录音中，当前显示：\(sourceName)（主语言）"
            } else {
                statusMessage = "录音中，当前显示：\(sourceName)（次语言兜底）"
            }
            return
        }

        let runningRecognizers: [SFSpeechRecognizer] = recognitionLocaleOrder.compactMap { localeIdentifier in
            guard recognitionTasks[localeIdentifier] != nil else { return nil }
            return speechRecognizers[localeIdentifier]
        }

        if hasActiveRecognitionTask(for: primaryRecognitionLanguage.languageCode) {
            statusMessage = "录音中，正在实时转写（主：\(primaryRecognitionLanguage.title)，次：\(secondaryRecognitionLanguage.title)）..."
        } else if !runningRecognizers.isEmpty {
            statusMessage = "录音中，主语言 \(primaryRecognitionLanguage.title) 尚未就绪，当前先使用 \(activeRecognitionLanguageSummary(from: runningRecognizers))；就绪后会自动接入。"
        } else {
            statusMessage = "录音中，正在等待识别器就绪（\(recognitionLanguageSummary())）..."
        }
    }

    private func persistRecognitionLanguages() {
        OmniKitStore.shared.set(primaryRecognitionLanguage.rawValue, forKey: Self.primaryRecognitionLanguageDefaultsKey)
        OmniKitStore.shared.set(secondaryRecognitionLanguage.rawValue, forKey: Self.secondaryRecognitionLanguageDefaultsKey)
    }

    private static func loadRecognitionLanguage(key: String) -> RecognitionLanguageOption? {
        guard let rawValue = OmniKitStore.shared.string(forKey: key) else { return nil }
        return RecognitionLanguageOption(rawValue: rawValue)
    }

    private static func normalizedRecognitionLanguages(
        primary: RecognitionLanguageOption,
        secondary: RecognitionLanguageOption
    ) -> (primary: RecognitionLanguageOption, secondary: RecognitionLanguageOption) {
        guard primary == secondary else { return (primary, secondary) }
        return (primary, fallbackRecognitionLanguage(excluding: primary))
    }

    private static func fallbackRecognitionLanguage(excluding excludedLanguage: RecognitionLanguageOption) -> RecognitionLanguageOption {
        if excludedLanguage != .english {
            return .english
        }
        return RecognitionLanguageOption.allCases.first(where: { $0 != excludedLanguage }) ?? .chinese
    }

    private func contextualStrings(for locale: Locale) -> [String] {
        let sharedTerms = [
            "OmniKit", "OpenAI", "ChatGPT", "API", "OCR", "Xcode", "macOS",
            "iPhone", "iPad", "Swift", "GitHub", "Python", "TypeScript",
            "JavaScript", "Docker", "Kubernetes", "AI"
        ]

        if locale.language.languageCode?.identifier == "zh" {
            return sharedTerms + ["实时转写", "会议纪要", "语音识别", "中文", "英文", "双语"]
        }

        return sharedTerms
    }

    private func updateRecognitionCandidate(locale: Locale, result: SFSpeechRecognitionResult) {
        let localeIdentifier = locale.identifier
        var candidate = recognitionCandidates[localeIdentifier] ?? RecognitionCandidate(locale: locale)
        candidate.text = normalizedTranscript(result.bestTranscription.formattedString)
        candidate.segmentCount = result.bestTranscription.segments.count
        candidate.isFinal = result.isFinal
        candidate.updatedAt = Date()
        recognitionCandidates[localeIdentifier] = candidate
        updateTranscriptLanguageLock(using: candidate)

        applyBestTranscript()

        if result.isFinal, isRecording {
            updateRecordingStatusMessage()
        }
    }

    private func applyBestTranscript() {
        guard let candidate = bestRecognitionCandidate(),
              let activeRecordID,
              let index = records.firstIndex(where: { $0.id == activeRecordID }) else {
            return
        }

        if displayedTranscriptLocaleIdentifier != candidate.locale.identifier {
            displayedTranscriptLocaleIdentifier = candidate.locale.identifier
            updateRecordingStatusMessage(displaying: candidate)
        }

        guard records[index].transcript != candidate.text else { return }
        records[index].transcript = candidate.text
        saveRecords()
    }

    private func bestRecognitionCandidate() -> RecognitionCandidate? {
        let candidates = recognitionLocaleOrder.compactMap { recognitionCandidates[$0] }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !candidates.isEmpty else { return nil }
        let analyses = candidates.map(makeCandidateAnalysis(for:))
        guard !analyses.isEmpty else { return nil }

        if let lockedLanguageCode = lockedTranscriptLanguageCode,
           let lockedCandidate = preferredCandidate(
            from: analyses,
            languageCode: lockedLanguageCode,
            requiringStrongSignal: true
           ) ?? preferredCandidate(
            from: analyses,
            languageCode: lockedLanguageCode,
            requiringStrongSignal: false
           ) {
            return lockedCandidate.candidate
        }

        if let primaryCandidate = preferredCandidate(
            from: analyses,
            language: primaryRecognitionLanguage,
            requiringStrongSignal: true
        ) {
            return primaryCandidate.candidate
        }

        if shouldAllowSecondaryFallback(),
           let secondaryCandidate = preferredCandidate(
            from: analyses,
            language: secondaryRecognitionLanguage,
            requiringStrongSignal: true
           ) {
            return secondaryCandidate.candidate
        }

        if let primaryFallback = preferredCandidate(
            from: analyses,
            language: primaryRecognitionLanguage,
            requiringStrongSignal: false
        ) {
            return primaryFallback.candidate
        }

        if shouldAllowSecondaryFallback(),
           let secondaryFallback = preferredCandidate(
            from: analyses,
            language: secondaryRecognitionLanguage,
            requiringStrongSignal: false
           ) {
            return secondaryFallback.candidate
        }

        return analyses.max(by: isLessPreferred)?.candidate
    }

    private func shouldAllowSecondaryFallback() -> Bool {
        let primaryLanguageCode = primaryRecognitionLanguage.languageCode

        guard hasActiveRecognitionTask(for: primaryLanguageCode) else {
            return true
        }

        let primaryCandidates = recognitionCandidates.values.filter {
            localeLanguageCode($0.locale) == primaryLanguageCode &&
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !primaryCandidates.isEmpty {
            let latestPrimaryUpdate = primaryCandidates.map(\.updatedAt).max() ?? .distantPast
            return Date().timeIntervalSince(latestPrimaryUpdate) > primaryRecognitionHoldInterval
        }

        guard let recognitionSessionStartedAt else {
            return false
        }

        return Date().timeIntervalSince(recognitionSessionStartedAt) >= secondaryRecognitionFallbackDelay
    }

    private func makeCandidateAnalysis(for candidate: RecognitionCandidate) -> RecognitionCandidateAnalysis {
        RecognitionCandidateAnalysis(
            candidate: candidate,
            recognizerLanguageCode: localeLanguageCode(candidate.locale),
            dominantLanguageCode: dominantLanguageCode(for: candidate.text),
            stats: transcriptStats(for: candidate.text)
        )
    }

    private func preferredCandidate(
        from analyses: [RecognitionCandidateAnalysis],
        language: RecognitionLanguageOption,
        requiringStrongSignal: Bool
    ) -> RecognitionCandidateAnalysis? {
        preferredCandidate(
            from: analyses,
            languageCode: language.languageCode,
            requiringStrongSignal: requiringStrongSignal
        )
    }

    private func preferredCandidate(
        from analyses: [RecognitionCandidateAnalysis],
        languageCode: String,
        requiringStrongSignal: Bool
    ) -> RecognitionCandidateAnalysis? {
        analyses
            .filter { analysis in
                guard analysis.recognizerLanguageCode == languageCode else { return false }
                return !requiringStrongSignal || hasStrongLanguageSignal(analysis, targetLanguageCode: languageCode)
            }
            .max(by: isLessPreferred)
    }

    private func updateTranscriptLanguageLock(using candidate: RecognitionCandidate) {
        let analysis = makeCandidateAnalysis(for: candidate)
        if hasStrongLanguageSignal(analysis, targetLanguageCode: analysis.recognizerLanguageCode) {
            lockedTranscriptLanguageCode = analysis.recognizerLanguageCode
        }
    }

    private func hasStrongLanguageSignal(
        _ analysis: RecognitionCandidateAnalysis,
        targetLanguageCode: String
    ) -> Bool {
        if analysis.dominantLanguageCode == targetLanguageCode {
            return true
        }

        switch targetLanguageCode {
        case "zh":
            return analysis.stats.chineseCount > 0
        case "en":
            return analysis.stats.latinCount >= 6 &&
                analysis.stats.chineseCount == 0 &&
                analysis.stats.kanaCount == 0 &&
                analysis.stats.hangulCount == 0
        case "ja":
            return analysis.stats.kanaCount > 0
        case "ko":
            return analysis.stats.hangulCount > 0
        default:
            return false
        }
    }

    private func isLessPreferred(_ lhs: RecognitionCandidateAnalysis, _ rhs: RecognitionCandidateAnalysis) -> Bool {
        let leftScore = score(for: lhs)
        let rightScore = score(for: rhs)
        if leftScore == rightScore {
            return lhs.candidate.updatedAt < rhs.candidate.updatedAt
        }
        return leftScore < rightScore
    }

    private func score(for analysis: RecognitionCandidateAnalysis) -> Int {
        let stats = analysis.stats
        let candidate = analysis.candidate
        let recognizerLanguageCode = analysis.recognizerLanguageCode

        var score = stats.chineseCount * 18
        score += stats.latinCount * 4
        score += stats.digitCount * 2
        score += candidate.segmentCount * 5

        if recognizerLanguageCode == primaryRecognitionLanguage.languageCode {
            score += 70
        } else if recognizerLanguageCode == secondaryRecognitionLanguage.languageCode {
            score += 24
        }

        if recognizerLanguageCode == "zh" {
            score += 180
            score += stats.chineseCount * 24
            score += stats.latinCount * 3
        }

        if recognizerLanguageCode == "en" {
            score += stats.latinCount * 4
            score -= 40
        }

        if analysis.dominantLanguageCode == recognizerLanguageCode {
            score += 140
        }

        if recognizerLanguageCode == "ja" {
            score += stats.kanaCount * 18
        }

        if recognizerLanguageCode == "ko" {
            score += stats.hangulCount * 18
        }

        if candidate.isFinal {
            score += 6
        }

        return score
    }

    private func transcriptStats(for text: String) -> TranscriptStats {
        var stats = TranscriptStats()

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F:
                stats.chineseCount += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                stats.kanaCount += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
                stats.hangulCount += 1
            case 0x30...0x39:
                stats.digitCount += 1
            case 0x41...0x5A, 0x61...0x7A:
                stats.latinCount += 1
            default:
                continue
            }
        }

        return stats
    }

    private func normalizedTranscript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dominantLanguageCode(for text: String) -> String? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return nil }
        return normalizedLanguageCode(from: language.rawValue)
    }

    private func localeLanguageCode(_ locale: Locale) -> String {
        normalizedLanguageCode(from: locale.identifier)
    }

    private func normalizedLanguageCode(from identifier: String) -> String {
        identifier.components(separatedBy: CharacterSet(charactersIn: "-_")).first?.lowercased() ?? identifier.lowercased()
    }

    private func displayName(for locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "zh":
            return "中文"
        case "en":
            return "English"
        default:
            return locale.identifier
        }
    }

    private func handleRecognitionError(_ error: Error, locale: Locale) {
        let localeIdentifier = locale.identifier
        recognitionTasks[localeIdentifier] = nil
        recognitionRequests[localeIdentifier] = nil

        if recognitionTasks.isEmpty, isRecording {
            statusMessage = "识别中断：\(recognitionLanguageSummary()) 通道都失败了。"
        } else if isRecording {
            statusMessage = "\(displayName(for: locale)) 识别中断：\(error.localizedDescription)"
        }
    }

    private func endRecognitionSession() {
        for request in recognitionRequests.values {
            request.endAudio()
        }
        for task in recognitionTasks.values {
            task.cancel()
        }

        recognitionRequests.removeAll()
        recognitionTasks.removeAll()
        recognitionCandidates.removeAll()
        recognitionLocaleOrder.removeAll()
        speechRecognizers.removeAll()
        lockedTranscriptLanguageCode = nil
        recognitionSessionStartedAt = nil
        displayedTranscriptLocaleIdentifier = nil
    }

    private func makeAudioURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let fileName = "meeting_\(formatter.string(from: Date())).caf"
        return meetingsDirectoryURL().appendingPathComponent(fileName)
    }

    private func meetingsDirectoryURL() -> URL {
        OmniKitDataLocation.ensureDirectoriesExist()
        return OmniKitDataLocation.meetingsDirectory
    }

    private func recordsFileURL() -> URL {
        OmniKitDataLocation.meetingRecordsURL
    }

    private func saveRecords() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: recordsFileURL(), options: .atomic)
        } catch {
            statusMessage = "保存录音记录失败：\(error.localizedDescription)"
        }
    }

    private func loadRecords() {
        let fileURL = recordsFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([MeetingRecord].self, from: data)
            records = decoded.sorted(by: { $0.startedAt > $1.startedAt })
        } catch {
            statusMessage = "读取录音记录失败：\(error.localizedDescription)"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingRecordID = nil
        isPlaybackPaused = false
        if flag {
            statusMessage = "播放完成"
        }
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if available {
                if self.isRecording {
                    self.startRecognitionTaskIfPossible(for: speechRecognizer)
                    self.updateRecordingStatusMessage()
                }
            } else if self.isRecording {
                self.statusMessage = "语音识别服务暂不可用：\(self.displayName(for: speechRecognizer.locale))"
            }
        }
    }
}

private func boostedRecognitionBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    switch buffer.format.commonFormat {
    case .pcmFormatFloat32:
        return boostedFloatBuffer(from: buffer)
    case .pcmFormatInt16:
        return boostedInt16Buffer(from: buffer)
    case .pcmFormatInt32:
        return boostedInt32Buffer(from: buffer)
    default:
        return nil
    }
}

private func boostedFloatBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let sourceChannels = buffer.floatChannelData,
          let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
          ),
          let destinationChannels = outputBuffer.floatChannelData else {
        return nil
    }

    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard channelCount > 0, frameCount > 0 else { return nil }

    let rms = rmsLevelFloat32(channels: sourceChannels, channelCount: channelCount, frameCount: frameCount)
    let gain = recognitionGain(for: rms)

    outputBuffer.frameLength = buffer.frameLength
    for channel in 0..<channelCount {
        let source = sourceChannels[channel]
        let destination = destinationChannels[channel]
        for frame in 0..<frameCount {
            destination[frame] = clampedFloatSample(source[frame] * gain)
        }
    }

    return outputBuffer
}

private func boostedInt16Buffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let sourceChannels = buffer.int16ChannelData,
          let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
          ),
          let destinationChannels = outputBuffer.int16ChannelData else {
        return nil
    }

    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard channelCount > 0, frameCount > 0 else { return nil }

    let rms = rmsLevelInt16(channels: sourceChannels, channelCount: channelCount, frameCount: frameCount)
    let gain = recognitionGain(for: rms)

    outputBuffer.frameLength = buffer.frameLength
    for channel in 0..<channelCount {
        let source = sourceChannels[channel]
        let destination = destinationChannels[channel]
        for frame in 0..<frameCount {
            let normalized = Float(source[frame]) / Float(Int16.max)
            let boosted = clampedFloatSample(normalized * gain)
            destination[frame] = Int16(boosted * Float(Int16.max))
        }
    }

    return outputBuffer
}

private func boostedInt32Buffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let sourceChannels = buffer.int32ChannelData,
          let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
          ),
          let destinationChannels = outputBuffer.int32ChannelData else {
        return nil
    }

    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard channelCount > 0, frameCount > 0 else { return nil }

    let rms = rmsLevelInt32(channels: sourceChannels, channelCount: channelCount, frameCount: frameCount)
    let gain = recognitionGain(for: rms)

    outputBuffer.frameLength = buffer.frameLength
    for channel in 0..<channelCount {
        let source = sourceChannels[channel]
        let destination = destinationChannels[channel]
        for frame in 0..<frameCount {
            let normalized = Float(source[frame]) / Float(Int32.max)
            let boosted = clampedFloatSample(normalized * gain)
            destination[frame] = Int32(boosted * Float(Int32.max))
        }
    }

    return outputBuffer
}

private func rmsLevelFloat32(
    channels: UnsafePointer<UnsafeMutablePointer<Float>>,
    channelCount: Int,
    frameCount: Int
) -> Float {
    var energy: Float = 0
    for channel in 0..<channelCount {
        let samples = channels[channel]
        for frame in 0..<frameCount {
            let value = samples[frame]
            energy += value * value
        }
    }
    return sqrt(energy / Float(channelCount * frameCount))
}

private func rmsLevelInt16(
    channels: UnsafePointer<UnsafeMutablePointer<Int16>>,
    channelCount: Int,
    frameCount: Int
) -> Float {
    var energy: Float = 0
    for channel in 0..<channelCount {
        let samples = channels[channel]
        for frame in 0..<frameCount {
            let value = Float(samples[frame]) / Float(Int16.max)
            energy += value * value
        }
    }
    return sqrt(energy / Float(channelCount * frameCount))
}

private func rmsLevelInt32(
    channels: UnsafePointer<UnsafeMutablePointer<Int32>>,
    channelCount: Int,
    frameCount: Int
) -> Float {
    var energy: Float = 0
    for channel in 0..<channelCount {
        let samples = channels[channel]
        for frame in 0..<frameCount {
            let value = Float(samples[frame]) / Float(Int32.max)
            energy += value * value
        }
    }
    return sqrt(energy / Float(channelCount * frameCount))
}

private func recognitionGain(for rms: Float) -> Float {
    guard rms.isFinite, rms > speechRecognitionNoiseFloor else {
        return 1
    }

    let targetGain = speechRecognitionTargetRMS / max(rms, speechRecognitionNoiseFloor)
    return min(max(targetGain, 1), speechRecognitionMaximumGain)
}

private func clampedFloatSample(_ value: Float) -> Float {
    min(max(value, -0.97), 0.97)
}
