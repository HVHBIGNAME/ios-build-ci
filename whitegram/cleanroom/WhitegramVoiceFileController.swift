import Foundation
import UIKit
import AsyncDisplayKit
import AccountContext
import Display
import TelegramCore
import TelegramPresentationData

private final class WhitegramVoiceExportDirectory {
    let url: URL
    init() throws {
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-voice-file-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: false)
    }
    deinit {
        do { try FileManager.default.removeItem(at: self.url) }
        catch { NSLog("WhitegramVoice: export staging cleanup failed") }
    }
}

public final class WhitegramVoiceFileController: ViewController, UIDocumentPickerDelegate {
    private let context: AccountContext
    private let status = UILabel()
    private let choose = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let export = UIButton(type: .system)
    private let stack = UIStackView()
    private var operation: WhitegramVoiceTask?
    private var generation = 0
    private var directory: WhitegramVoiceExportDirectory?
    private var output: URL?
    private var validLayout: ContainerViewLayout?

    public init(context: AccountContext) {
        self.context = context
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = "Audio / Video Conversion"
    }

    required public init(coder: NSCoder) { preconditionFailure() }

    deinit {
        self.operation?.cancel()
        self.removeOutput()
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
        self.displayNode.backgroundColor = presentation.theme.list.blocksBackgroundColor
        self.status.numberOfLines = 0
        self.status.textColor = presentation.theme.list.itemPrimaryTextColor
        self.status.text = "Choose an audio or video file to process with your saved Voice Effects settings. Video keeps its picture and timing; only its audio is replaced. The result is exported to Files."
        self.choose.setTitle("Choose Audio / Video", for: .normal)
        self.choose.addTarget(self, action: #selector(self.chooseFile), for: .touchUpInside)
        self.cancel.setTitle("Cancel Processing", for: .normal)
        self.cancel.addTarget(self, action: #selector(self.cancelProcessing), for: .touchUpInside)
        self.cancel.isEnabled = false
        self.export.setTitle("Export Result", for: .normal)
        self.export.addTarget(self, action: #selector(self.exportFile), for: .touchUpInside)
        self.export.isEnabled = false
        self.stack.axis = .vertical
        self.stack.spacing = 18
        for view in [self.status, self.choose, self.cancel, self.export] { self.stack.addArrangedSubview(view) }
        self.displayNode.view.addSubview(self.stack)
        super.displayNodeDidLoad()
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY + 24
        let width = max(0, layout.size.width - layout.safeInsets.left - layout.safeInsets.right - 40)
        let height = self.stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        self.stack.frame = CGRect(x: layout.safeInsets.left + 20, y: top, width: width, height: height)
    }

    private func showStatus(_ text: String) {
        self.status.text = text
        if let layout = self.validLayout { self.containerLayoutUpdated(layout, transition: .immediate) }
    }

    @objc private func chooseFile() {
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        guard settings.hasLocalEffect || settings.activeBleepMode != nil || settings.requiresPostprocessing else {
            self.showStatus("Enable a voice effect or word bleeping in Voice Effects first.")
            return
        }
        let picker = UIDocumentPickerViewController(documentTypes: ["public.audio", "public.movie", "org.xiph.ogg-audio"], in: .import)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.present(picker, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller.documentPickerMode == .import, let url = urls.first else { return }
        self.cancelProcessing()
        self.removeOutput()
        let task = WhitegramVoiceTask()
        self.operation = task
        let generation = self.generation
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        let locale = self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
        self.showStatus("Processing…")
        self.choose.isEnabled = false
        self.cancel.isEnabled = true
        self.export.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                task.onCancel { coordinator.cancel() }
                var error: NSError?
                var prepared: Result<(WhitegramVoiceExportDirectory, Data), Error>?
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
                    prepared = Result {
                        let bytes = try WhitegramVoiceVideo.read(location, maximumBytes: 256 * 1024 * 1024, task: task)
                        let directory = try WhitegramVoiceExportDirectory()
                        return (directory, bytes)
                    }
                }
                if let error { throw error }
                guard let prepared else { throw WhitegramVoiceProcessingError.invalidAudio }
                let (directory, bytes) = try prepared.get()
                let ext = url.pathExtension.lowercased()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation, !task.isCancelled else {
                        return
                    }
                    self.directory = directory
                    let complete: (Result<Data, WhitegramVoiceProcessingError>, String) -> Void = { [weak self] result, ext in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try task.check()
                                let data = try result.get()
                                let output = directory.url.appendingPathComponent("Whitegram-voice." + ext)
                                try data.write(to: output, options: .atomic)
                                DispatchQueue.main.async {
                                    guard let self, self.generation == generation, !task.isCancelled else { return }
                                    self.output = output
                                    self.operation = nil
                                    task.cancel()
                                    self.choose.isEnabled = true
                                    self.cancel.isEnabled = false
                                    self.export.isEnabled = true
                                    self.showStatus("Conversion complete. Export the result to Files.")
                                }
                            } catch {
                                DispatchQueue.main.async { [weak self] in self?.failed(error, generation: generation) }
                            }
                        }
                    }
                    if ["mp4", "mov", "m4v"].contains(ext) {
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try task.check()
                                let input = directory.url.appendingPathComponent("input." + ext)
                                try bytes.write(to: input, options: .atomic)
                                let processing = WhitegramVoiceVideo.process(urls: [input], settings: settings, locale: locale) {
                                    complete($0.map(\.data), "mp4")
                                    withExtendedLifetime(directory) {}
                                }
                                task.onCancel { processing.cancel() }
                            } catch { complete(.failure(.conversion(error)), "mp4") }
                        }
                    } else {
                        let processing = WhitegramVoicePostprocessor.process(data: bytes, fileExtension: ext, settings: settings, locale: locale, applyLocalEffects: true) { complete($0.map(\.data), "ogg") }
                        task.onCancel { processing.cancel() }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.failed(error, generation: generation) }
            }
        }
    }

    private func failed(_ error: Error, generation: Int) {
        guard self.generation == generation else { return }
        self.operation?.cancel()
        self.operation = nil
        self.choose.isEnabled = true
        self.cancel.isEnabled = false
        self.showStatus(error.localizedDescription)
    }

    @objc private func cancelProcessing() {
        self.generation += 1
        self.operation?.cancel()
        self.operation = nil
        self.choose.isEnabled = true
        self.cancel.isEnabled = false
        self.showStatus("Choose a file to process.")
    }

    @objc private func exportFile() {
        guard let output else { return }
        let picker = UIDocumentPickerViewController(url: output, in: .exportToService)
        self.present(picker, animated: true)
    }

    private func removeOutput() {
        self.directory = nil
        self.output = nil
    }
}
