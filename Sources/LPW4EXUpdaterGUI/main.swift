import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct LPW4EXUpdaterApp: App {
    var body: some Scene {
        WindowGroup {
            UpdaterView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published var firmwareURL: URL?
    @Published var accepted = false
    @Published var isRunning = false
    @Published var status = "W4EXをUSB接続し、接続確認を実行する"
    @Published var log = ""
    @Published var showConfirmation = false

    var canUpdate: Bool {
        firmwareURL != nil && accepted && !isRunning
    }

    func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.title = "公式W4EXファームウェアを選択"
        panel.prompt = "選択"
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        firmwareURL = url
        accepted = false
        status = "ファイルを選択した。W4EX用であることを確認する"
    }

    func scan() {
        runCLI(arguments: ["scan"], operation: "接続確認") { [weak self] succeeded, output in
            self?.status = succeeded && output.contains("PID_F82D")
                ? "W4EX候補（VID 2FC6 / PID F82D）を検出"
                : "対象デバイスを確認できない"
        }
    }

    func requestUpdate() {
        guard canUpdate else { return }
        showConfirmation = true
    }

    func update() {
        guard let firmwareURL, canUpdate else { return }
        runCLI(
            arguments: [
                "update", firmwareURL.path,
                "--model", "W4EX",
                "--accept-unverified-w4ex-firmware",
                "--yes"
            ],
            operation: "FW更新",
            preventSleep: true
        ) { [weak self] succeeded, output in
            if succeeded && output.contains("Verifying Success") {
                self?.status = "更新成功。USBを一度抜き、再接続してUpdating完了を待つ"
            } else {
                self?.status = "更新失敗。USBを抜かず、ログを確認する"
            }
        }
    }

    private func runCLI(
        arguments: [String],
        operation: String,
        preventSleep: Bool = false,
        completion: @escaping @MainActor (Bool, String) -> Void
    ) {
        guard !isRunning else { return }
        guard let cliURL = locateCLI() else {
            status = "同梱CLIが見つからない"
            return
        }

        isRunning = true
        status = "\(operation)を実行中…"
        log = "$ lpw4ex-updater \(arguments.map(shellDisplay).joined(separator: " "))\n\n"

        let process = Process()
        let pipe = Pipe()
        if preventSleep {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-dimsu", cliURL.path] + arguments
        } else {
            process.executableURL = cliURL
            process.arguments = arguments
        }
        process.standardOutput = pipe
        process.standardError = pipe

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                Task { @MainActor in
                    self?.log += output
                    self?.isRunning = false
                    completion(process.terminationStatus == 0, output)
                }
            } catch {
                Task { @MainActor in
                    self?.log += "Error: \(error.localizedDescription)\n"
                    self?.isRunning = false
                    self?.status = "\(operation)を開始できない"
                    completion(false, "")
                }
            }
        }
    }

    private func locateCLI() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let executableURL = Bundle.main.executableURL {
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent("lpw4ex-updater-cli"))
            candidates.append(executableURL.deletingLastPathComponent().appendingPathComponent("lpw4ex-updater"))
        }
        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("lpw4ex-updater-universal"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func shellDisplay(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}

struct UpdaterView: View {
    @StateObject private var model = UpdaterModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("L&P W4EX Firmware Updater")
                    .font(.title2.bold())
                Text("非公式macOSツール — 更新中はUSBを抜かないこと")
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("接続確認") { model.scan() }
                    .disabled(model.isRunning)
                Button("FWファイルを選択…") { model.chooseFirmware() }
                    .disabled(model.isRunning)
                Text(model.firmwareURL?.lastPathComponent ?? "未選択")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(model.firmwareURL == nil ? .secondary : .primary)
            }

            Toggle("選択したファイルがL&P W4EX用の公式FWであることを確認した", isOn: $model.accepted)
                .disabled(model.firmwareURL == nil || model.isRunning)

            HStack {
                Button("FW UPDATE") { model.requestUpdate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canUpdate)
                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(model.status)
                    .foregroundColor(.secondary)
            }

            TextEditor(text: $model.log)
                .font(.system(.body, design: .monospaced))
                .disabled(true)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
        }
        .padding(20)
        .alert("FW更新を開始する", isPresented: $model.showConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("更新開始", role: .destructive) { model.update() }
        } message: {
            Text("更新完了とVerifying Successが表示されるまで、USBを抜かずMacをスリープさせないこと。")
        }
    }
}
