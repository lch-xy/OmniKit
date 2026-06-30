//
//  MeetingConfigView.swift
//  OmniKit
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingConfigView: View {
    @EnvironmentObject private var meetingManager: MeetingManager
    @State private var presentedRecordID: MeetingRecord.ID?
    @State private var presentedSummaryRecordID: MeetingRecord.ID?
    @State private var renamingRecordID: MeetingRecord.ID?
    @State private var draftRecordTitle = ""
    @State private var draftDeepSeekAPIKey = ""
    @State private var draftDeepSeekModel = MeetingManager.defaultDeepSeekModel
    @State private var deepSeekSaveMessage = ""
    @State private var currentPage = 1
    private let pageSize = 10

    var body: some View {
        SettingsCanvas {
            SettingsHeroCard(
                title: "会议录音",
                subtitle: "记录会议语音、实时转写并保留完整音频文件。可配置主要和次要识别语言，命名、查看文本和回放都集中在这里完成。"
            ) {
                HStack(spacing: 12) {
                    Button {
                        meetingManager.openRecordingsFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("打开录音文件夹")

                    Button(meetingManager.isRecording ? "结束录音" : "开始录音") {
                        if meetingManager.isRecording {
                            meetingManager.stopRecording()
                        } else {
                            meetingManager.startRecording()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(meetingManager.isRecording ? .red : .accentColor)
                }
            }

            SettingsSection(title: "识别语言") {
                SettingsRow("主要语言", systemImage: "1.circle", description: "优先使用的识别语言") {
                    Picker("", selection: primaryRecognitionLanguageBinding) {
                        ForEach(RecognitionLanguageOption.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                SettingsDivider()

                SettingsRow("次要语言", systemImage: "2.circle", description: "主语言不匹配时用于兜底识别") {
                    Picker("", selection: secondaryRecognitionLanguageBinding) {
                        ForEach(RecognitionLanguageOption.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            SettingsSection(title: "实时状态") {
                SettingsRow("录音状态", systemImage: "waveform.and.mic", description: meetingManager.statusMessage) {
                    if meetingManager.isRecording {
                        SettingsInfoBadge(text: "正在录音", tint: .red)
                    } else {
                        SettingsInfoBadge(text: "就绪", tint: .secondary)
                    }
                }
            }

            SettingsSection(title: "AI 摘要") {
                SettingsRow("DeepSeek API Key", systemImage: "key", description: "用于调用 DeepSeek 生成会议摘要") {
                    SecureField("必填", text: $draftDeepSeekAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                SettingsDivider()

                SettingsRow("模型", systemImage: "brain", description: "默认使用 DeepSeek 官方当前推荐的 v4 pro 模型") {
                    TextField(MeetingManager.defaultDeepSeekModel, text: $draftDeepSeekModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }

                SettingsDivider()

                SettingsRow("保存配置", systemImage: "tray.and.arrow.down") {
                    HStack {
                        if !deepSeekSaveMessage.isEmpty {
                            SettingsInfoBadge(text: deepSeekSaveMessage, tint: .green)
                        }
                        Button("保存") {
                            meetingManager.deepSeekAPIKey = draftDeepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            meetingManager.deepSeekModel = draftDeepSeekModel.trimmingCharacters(in: .whitespacesAndNewlines)
                            deepSeekSaveMessage = "已保存"
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            SettingsSection(title: "录音历史") {
                if meetingManager.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("暂无录音记录")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(pagedRecords.enumerated()), id: \.element.id) { index, record in
                            recordRow(record)
                            if index < pagedRecords.count - 1 {
                                SettingsDivider()
                            }
                        }
                    }
                    
                    Divider()
                    
                    HStack {
                        Button {
                            currentPage = max(1, currentPage - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(currentPage <= 1)
                        .buttonStyle(.plain)

                        Spacer()
                        Text("\(currentPage) / \(totalPages)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            currentPage = min(totalPages, currentPage + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(currentPage >= totalPages)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .onDisappear {
            if meetingManager.isRecording {
                meetingManager.stopRecording()
            }
        }
        .onAppear {
            adjustCurrentPageIfNeeded()
            draftDeepSeekAPIKey = meetingManager.deepSeekAPIKey
            draftDeepSeekModel = meetingManager.deepSeekModel
        }
        .onChange(of: meetingManager.records.count) { _, _ in
            adjustCurrentPageIfNeeded()
        }
        .sheet(isPresented: presentedTranscriptBinding) {
            transcriptSheet
        }
        .sheet(isPresented: presentedSummaryBinding) {
            summarySheet
        }
        .sheet(isPresented: renamingRecordBinding) {
            renameSheet
        }
    }

    private func recordRow(_ record: MeetingRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if record.id == meetingManager.records.first?.id && meetingManager.isRecording {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }
                    Text(record.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(record.startedAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 14) {
                Button { meetingManager.playRecord(record.id) } label: {
                    Image(systemName: playbackIcon(for: record.id))
                }
                .help(playbackHelpText(for: record.id))

                Button { presentedRecordID = record.id } label: {
                    Image(systemName: "text.alignleft")
                }
                .help("查看文本")

                Button { presentedSummaryRecordID = record.id } label: {
                    if meetingManager.isGeneratingSummary(for: record.id) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 13, height: 13)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .disabled(meetingManager.isGeneratingSummary(for: record.id))
                .help("查看摘要")

                Button { exportMarkdown(record) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("导出 Markdown")

                Button { beginRenaming(record) } label: {
                    Image(systemName: "pencil")
                }
                .help("重命名")

                Button(role: .destructive) { meetingManager.deleteRecord(record.id) } label: {
                    Image(systemName: "trash")
                }
                .foregroundStyle(.red.opacity(0.8))
                .help("删除")
            }
            .font(.system(size: 13))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(meetingManager.records.count) / Double(pageSize))))
    }

    private var pagedRecords: [MeetingRecord] {
        let start = (currentPage - 1) * pageSize
        guard start < meetingManager.records.count else { return [] }
        let end = min(start + pageSize, meetingManager.records.count)
        return Array(meetingManager.records[start..<end])
    }

    private func adjustCurrentPageIfNeeded() {
        currentPage = min(max(1, currentPage), totalPages)
    }

    private func playbackIcon(for id: MeetingRecord.ID) -> String {
        if meetingManager.playingRecordID == id && !meetingManager.isPlaybackPaused {
            return "pause.circle"
        }
        return "play.circle"
    }

    private func playbackHelpText(for id: MeetingRecord.ID) -> String {
        if meetingManager.playingRecordID == id && !meetingManager.isPlaybackPaused {
            return "暂停"
        }
        return "播放"
    }

    private var primaryRecognitionLanguageBinding: Binding<RecognitionLanguageOption> {
        Binding(
            get: { meetingManager.primaryRecognitionLanguage },
            set: { meetingManager.setPrimaryRecognitionLanguage($0) }
        )
    }

    private var secondaryRecognitionLanguageBinding: Binding<RecognitionLanguageOption> {
        Binding(
            get: { meetingManager.secondaryRecognitionLanguage },
            set: { meetingManager.setSecondaryRecognitionLanguage($0) }
        )
    }

    private var transcriptSheet: some View {
        TranscriptSheet(recordID: presentedRecordID) {
            presentedRecordID = nil
        }
        .environmentObject(meetingManager)
    }

    private var summarySheet: some View {
        MeetingSummarySheet(recordID: presentedSummaryRecordID) {
            presentedSummaryRecordID = nil
        }
        .environmentObject(meetingManager)
    }

    private var renameSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("修改会议记录名称")
                    .font(.system(size: 13, weight: .semibold))
                TextField("名称", text: $draftRecordTitle)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelRenaming() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveRenaming() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: 360, height: 180)
    }

    private var presentedTranscriptBinding: Binding<Bool> {
        Binding(get: { presentedRecordID != nil }, set: { if !$0 { presentedRecordID = nil } })
    }

    private var presentedSummaryBinding: Binding<Bool> {
        Binding(get: { presentedSummaryRecordID != nil }, set: { if !$0 { presentedSummaryRecordID = nil } })
    }

    private var renamingRecordBinding: Binding<Bool> {
        Binding(get: { renamingRecordID != nil }, set: { if !$0 { cancelRenaming() } })
    }

    private func beginRenaming(_ record: MeetingRecord) {
        renamingRecordID = record.id
        draftRecordTitle = record.title
    }

    private func cancelRenaming() {
        renamingRecordID = nil
        draftRecordTitle = ""
    }

    private func saveRenaming() {
        if let id = renamingRecordID {
            meetingManager.renameRecord(id, to: draftRecordTitle)
        }
        cancelRenaming()
    }

    private func exportMarkdown(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(safeFilename(record.title)).md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try markdownContent(for: record).write(to: url, atomically: true, encoding: .utf8)
            meetingManager.statusMessage = "已导出 Markdown：\(url.lastPathComponent)"
        } catch {
            meetingManager.statusMessage = "导出 Markdown 失败：\(error.localizedDescription)"
        }
    }

    private func markdownContent(for record: MeetingRecord) -> String {
        let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        # \(record.title)

        \(summary?.isEmpty == false ? summary! : "暂无摘要。")
        """
    }

    private func safeFilename(_ text: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let name = text.components(separatedBy: invalidCharacters).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "会议记录" : name
    }
}

private struct TranscriptSheet: View {
    @EnvironmentObject private var meetingManager: MeetingManager
    let recordID: MeetingRecord.ID?
    let onClose: () -> Void

    private var record: MeetingRecord? {
        guard let id = recordID else { return nil }
        return meetingManager.record(for: id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(record?.transcript ?? "暂无内容")
                        .font(.system(size: 13))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                }
                .padding(24)
            }
            .navigationTitle(record?.title ?? "转写结果")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

private struct MeetingSummarySheet: View {
    @EnvironmentObject private var meetingManager: MeetingManager
    let recordID: MeetingRecord.ID?
    let onClose: () -> Void

    private var record: MeetingRecord? {
        guard let id = recordID else { return nil }
        return meetingManager.record(for: id)
    }

    private var summaryText: String {
        let summary = record?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? "正在生成摘要..." : summary
    }

    private var errorText: String? {
        guard let recordID else { return nil }
        return meetingManager.summaryError(for: recordID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let recordID, meetingManager.isGeneratingSummary(for: recordID) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在生成摘要...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text(summaryText)
                            .font(.system(size: 13))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle(record?.title ?? "AI 摘要")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("重新生成") {
                        guard let recordID else { return }
                        Task {
                            await meetingManager.regenerateSummary(for: recordID)
                        }
                    }
                    .disabled(recordID == nil || recordID.map(meetingManager.isGeneratingSummary(for:)) == true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .task(id: recordID) {
            guard let recordID else { return }
            await meetingManager.generateSummaryIfNeeded(for: recordID)
        }
    }
}
