// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

@MainActor
final class Manager: ObservableObject {
    @Published var facts = SystemFacts()
    @Published var probing = false
    @Published var release: Release?
    @Published var releaseError: String?
    @Published var checkingRelease = false
    @Published var package: Package?
    @Published var packageStatus: [String: String] = [:]
    @Published var zinkPackage: Package?
    @Published var busy: String?
    @Published var log = ""
    @Published var lastResult: String?
    @Published var rebootNeeded = false
    @Published var efiNotice: EFINotice?
    @Published var efi = EFIStatus()
    @Published var efiTarget = EFITarget.recorded
    @Published var efiPlans: [EFIAction: EFIPlan] = [:]
    @Published var efiChoice: String? = UserDefaults.standard.string(forKey: "efiPartition")
    @Published var requestedSection: Section?
    private var logTimer: Timer?

    init() {
        package = Self.savedPackage(key: "package")
        zinkPackage = Self.savedPackage(key: "zinkPackage")
    }

    private static func savedPackage(key: String) -> Package? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        let package = Package(directory: URL(fileURLWithPath: path))
        return package.isValid ? package : nil
    }

    func refresh() async {
        probing = true
        facts = await Task.detached { SystemFacts.probe() }.value
        await refreshPackageStatus()
        await refreshEFI()
        probing = false
    }

    /// efi.sh --status, and its plans when the EFI can be read. The EFI is the one OpenCore recorded; when it recorded
    /// none, the partition chosen on the EFI page (by UUID).
    func refreshEFI() async {
        guard let package, let script = efiScript(for: package) else { efi = EFIStatus(); efiPlans = [:]; return }
        let choice = efiChoice
        let test = ProcessInfo.processInfo.environment["INTELXE_MANAGER_TEST_EFI"]
        let (status, target, plans) = await Task.detached { () -> (EFIStatus, EFITarget, [EFIAction: EFIPlan]) in
            var target = test.map { EFITarget.folder($0) } ?? .recorded
            var status = efiStatus(script: script, package: package, target: target)
            if !status.found, let choice, status.candidates.contains(where: { $0.uuid == choice }) {
                target = .partition(choice)
                status = efiStatus(script: script, package: package, target: target)
            }
            var plans: [EFIAction: EFIPlan] = [:]
            if status.readable && status.isOpenCore {
                for action in [EFIAction.apply, .settings, .undo] {
                    if let argument = action.planArgument, let plan = efiPlan(script: script, package: package, target: target, argument) {
                        plans[action] = plan
                    }
                }
            }
            return (status, target, plans)
        }.value
        efi = status
        efiTarget = target
        efiPlans = plans
    }

    func chooseEFIPartition(_ uuid: String) {
        efiChoice = uuid
        UserDefaults.standard.set(uuid, forKey: "efiPartition")
        Task { await refreshEFI() }
    }

    func refreshPackageStatus() async {
        guard let package else { packageStatus = [:]; return }
        packageStatus = await Task.detached { package.status() }.value
    }

    func checkForUpdate() async {
        checkingRelease = true
        releaseError = nil
        do { release = try await latestRelease() } catch { releaseError = error.localizedDescription }
        checkingRelease = false
    }

    var installedVersion: Version? { facts.installedVersion.flatMap(Version.init) }

    var updateAvailable: Bool {
        guard let latest = release?.version, facts.driverFilesPresent else { return false }
        guard let installed = installedVersion else { return true }
        return latest > installed
    }

    func choose(_ package: Package, zink: Bool) {
        if zink {
            zinkPackage = package
            UserDefaults.standard.set(package.directory.path, forKey: "zinkPackage")
        } else {
            self.package = package
            UserDefaults.standard.set(package.directory.path, forKey: "package")
            Task { await refreshPackageStatus(); await refreshEFI() }
        }
    }

    func pickFolder(zink: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose an unpacked package: the folder with install.sh in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = Package(directory: url)
        guard picked.isValid else {
            lastResult = String(localized: "That folder is not a package: it has no install.sh and SHA256SUMS.")
            return
        }
        choose(picked, zink: zink)
    }

    func downloadLatest(zink: Bool) async {
        guard let release else { return }
        guard let suffix = zink ? "-zink-gl.zip" : packageSuffix(macOSMajor: facts.macOSMajor) else {
            lastResult = String(localized: "There is no package for this version of macOS.")
            return
        }
        busy = String(localized: "Downloading")
        defer { busy = nil }
        do {
            let downloaded = try await download(release, suffix: suffix) { text in
                Task { @MainActor in self.appendLog(text + "\n") }
            }
            choose(downloaded, zink: zink)
        } catch { lastResult = error.localizedDescription }
    }

    private func appendLog(_ text: String) { log += text }

    private func perform(title: String, command: String, needsRoot: Bool, then done: @escaping @MainActor (RunResult) -> Void,
                         afterRefresh: (@MainActor () -> Void)? = nil) {
        let logs = dataDirectory.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = logs.appendingPathComponent("\(formatter.string(from: Date())).log")
        busy = title
        lastResult = nil
        log += "\n== \(title)\n"
        let start = log.count
        // install.sh writes to the log file as it works; rebuilding the kernel collection takes minutes.
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
                self.log = String(self.log.prefix(start)) + text
            }
        }
        let prompt = String(localized: "IntelXe Manager needs an administrator password for: \(title)")
        Task.detached {
            let result = run(command: command, needsRoot: needsRoot, log: file, prompt: prompt)
            await MainActor.run {
                self.logTimer?.invalidate()
                if let text = try? String(contentsOf: file, encoding: .utf8) { self.log = String(self.log.prefix(start)) + text }
                self.busy = nil
                if !result.cancelled && !result.succeeded && !result.message.isEmpty { self.log += result.message + "\n" }
                done(result)
                Task {
                    await self.refresh()
                    afterRefresh?()
                }
            }
        }
    }

    func perform(_ action: DriverAction) {
        guard let package else { return }
        let command = "\(shellQuoted(package.script.path)) \(action.argument)"
        var succeeded = false
        perform(title: action.title, command: command, needsRoot: action.needsRoot, then: { result in
            if result.cancelled {
                self.lastResult = String(localized: "Cancelled. Nothing changed.")
            } else if result.succeeded {
                self.lastResult = String(localized: "Finished.")
                if action.needsReboot { self.rebootNeeded = true }
                succeeded = true
            } else {
                self.lastResult = String(localized: "It did not finish. See the log.")
            }
        }, afterRefresh: {
            // the EFI as it is after the refresh: a notice only when its IntelXe.kext is not this package's or could not be read
            if succeeded { self.efiNotice = EFINotice.after(action, status: self.efi) }
        })
    }

    /// An EFI change through efi.sh, with the hash of the plan that was shown: efi.sh refuses if the EFI changed since.
    func performEFI(_ action: EFIAction) {
        guard let package, let script = efiScript(for: package) else { return }
        var words = efiWords(script: script, package: package, target: efiTarget, action.argument)
        if action.planArgument != nil {
            guard let plan = efiPlans[action] else { return }
            words += ["--expect", plan.hash]
        }
        perform(title: action.title, command: words.map(shellQuoted).joined(separator: " "), needsRoot: true, then: { result in
            if result.cancelled {
                self.lastResult = String(localized: "Cancelled. Nothing changed.")
            } else if result.succeeded {
                self.lastResult = action == .mount ? String(localized: "Mounted.") : String(localized: "Finished. Restart to use the change.")
                if action != .mount { self.rebootNeeded = true }
            } else {
                self.lastResult = String(localized: "It did not finish. See the log.")
            }
        }, afterRefresh: {
            if action != .mount, let notice = self.efiNotice, notice != .removeKext {
                self.efiNotice = EFINotice.after(.install, status: self.efi)
            }
        })
    }

    func performZink(_ action: ZinkAction) {
        guard let zinkPackage else { return }
        let script = shellQuoted(zinkPackage.directory.appendingPathComponent("install.sh").path)
        perform(title: action.title, command: "\(script) \(action.arguments)", needsRoot: action.needsRoot, then: { result in
            self.lastResult = result.cancelled ? String(localized: "Cancelled. Nothing changed.")
                : result.succeeded ? String(localized: "Finished.") : String(localized: "It did not finish. See the log.")
        })
    }

    func clearBootGuard() {
        perform(title: String(localized: "Clear the boot guard"), command: "/usr/sbin/nvram intelxe-accel-off=ok", needsRoot: true, then: { result in
            self.lastResult = result.succeeded ? String(localized: "Cleared. It takes effect at the next boot.") : String(localized: "It did not finish. See the log.")
            if result.succeeded { self.rebootNeeded = true }
        })
    }
}

extension DriverAction {
    var title: String {
        switch self {
        case .check: return String(localized: "Check")
        case .install: return String(localized: "Install this package")
        case .repair: return String(localized: "Repair")
        case .undo: return String(localized: "Undo the last install")
        case .uninstall: return String(localized: "Uninstall")
        }
    }
    var explanation: String {
        switch self {
        case .check: return String(localized: "Checks the system and the package. Changes nothing.")
        case .install: return String(localized: "Backs up what it replaces, copies the kexts and the Metal driver into /Library, and rebuilds the Auxiliary Kernel Collection. This takes a few minutes. Then restart.")
        case .repair: return String(localized: "Puts back installed files that differ from this package. The last backup stays as it is.")
        case .undo: return String(localized: "Puts the last backup back and rebuilds the Auxiliary Kernel Collection. Then restart.")
        case .uninstall: return String(localized: "Removes the kexts and the Metal driver from /Library. Backups stay. Remove IntelXe.kext from your EFI before you restart, or macOS comes up without the driver.")
        }
    }
    var confirms: Bool { self != .check }
    var destructive: Bool { self == .undo || self == .uninstall }
}

extension ZinkAction {
    var title: String {
        switch self {
        case .install: return String(localized: "Install Zink")
        case .undo: return String(localized: "Remove Zink")
        case .globalOn: return String(localized: "Use Zink for every LWJGL application")
        case .globalOff: return String(localized: "Back to Apple's OpenGL")
        case .test: return String(localized: "Run the self-test")
        }
    }
}

enum Section: String, CaseIterable, Identifiable {
    case system, driver, efi, zink, log
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .driver: return "Driver"
        case .efi: return "EFI (OpenCore)"
        case .zink: return "OpenGL (Zink)"
        case .log: return "Log"
        }
    }
    var icon: String {
        switch self {
        case .system: return "cpu"
        case .driver: return "shippingbox"
        case .efi: return "externaldrive"
        case .zink: return "cube.transparent"
        case .log: return "text.alignleft"
        }
    }
}

// Plain observable state: this builds with the command line tools alone, whose toolchain has no SwiftUI macro plugin.
final class PageState: ObservableObject {
    @Published var section: Section? = .system
    @Published var confirming: DriverAction?
}

struct RootView: View {
    @EnvironmentObject var manager: Manager
    @StateObject var page = PageState()

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $page.section) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            VStack(spacing: 0) {
                Banners()
                switch page.section ?? .system {
                case .system: SystemView()
                case .driver: DriverView()
                case .efi: EFIView()
                case .zink: ZinkView()
                case .log: LogView()
                }
            }
            .frame(minWidth: 560, minHeight: 460)
        }
        .disabled(manager.busy != nil)
        .overlay(alignment: .bottom) { BusyBar() }
        .onChange(of: manager.requestedSection) { _, section in
            if let section { page.section = section; manager.requestedSection = nil }
        }
        .task {
            await manager.refresh()
            await manager.checkForUpdate()
        }
    }
}

struct BusyBar: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        if let busy = manager.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(busy)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(14)
        }
    }
}

struct Banners: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        VStack(spacing: 0) {
            if let notice = manager.efiNotice {
                Banner(symbol: "externaldrive.badge.exclamationmark", tint: .orange, text: notice.text) {
                    Button("Open the EFI page") { manager.requestedSection = .efi }
                    Button("Done") { manager.efiNotice = nil }
                }
            }
            if manager.rebootNeeded {
                Banner(symbol: "arrow.clockwise", tint: .accentColor, text: "Restart to use the change.") {
                    Button("Later") { manager.rebootNeeded = false }
                }
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey
    @ViewBuilder let actions: Actions
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(tint.opacity(0.1))
    }
}

struct SystemView: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        Form {
            Section2(title: "This Mac") {
                ForEach(manager.facts.checks) { check in
                    CheckRow(check: check)
                }
            }
            if manager.facts.bootGuardOff {
                Button("Clear the boot guard") { manager.clearBootGuard() }
            }
            Section2(title: "Driver") {
                LabeledContent("Installed") { Text(installedText) }
                LabeledContent("Latest release") { Text(releaseText) }
                if manager.updateAvailable {
                    Label("A newer release is available. See the Driver page.", systemImage: "arrow.down.circle")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button { Task { await manager.refresh(); await manager.checkForUpdate() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(manager.probing)
            }
        }
    }

    var installedText: String {
        if let version = manager.facts.installedVersion { return version }
        return manager.facts.driverFilesPresent ? String(localized: "Installed, version not recorded (before 0.1.2)") : String(localized: "Not installed")
    }

    var releaseText: String {
        if manager.checkingRelease { return String(localized: "Checking…") }
        if let error = manager.releaseError { return error }
        return manager.release?.version?.description ?? "–"
    }
}

struct Section2<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View { SwiftUI.Section { content } header: { Text(title) } }
}

struct CheckRow: View {
    let check: Check
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color).accessibilityLabel(stateLabel)
                Text(LocalizedStringKey(check.title))
                Spacer()
                Text(LocalizedStringKey(check.value)).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
            if !check.help.isEmpty {
                Text(LocalizedStringKey(check.help)).font(.callout).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
    }
    var symbol: String {
        switch check.state {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .neutral: return "circle"
        }
    }
    var color: Color {
        switch check.state {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
    var stateLabel: LocalizedStringKey {
        switch check.state {
        case .good: return "OK"
        case .warning: return "Warning"
        case .bad: return "Problem"
        case .neutral: return ""
        }
    }
}

struct DriverView: View {
    @EnvironmentObject var manager: Manager
    @StateObject var page = PageState()

    var body: some View {
        Form {
            Section2(title: "Package") {
                if let package = manager.package {
                    LabeledContent("Folder") { Text(package.directory.path).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
                    LabeledContent("Version") { Text(manager.packageStatus["package_version"] ?? "–") }
                    LabeledContent("Compared with what is installed") { Text(stateText) }
                } else {
                    Text("Choose a package before you install or repair. Download the latest release, or use a folder you unpacked.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let release = manager.release {
                        Button("Download \(release.tag_name)") { Task { await manager.downloadLatest(zink: false) } }
                    } else if let error = manager.releaseError {
                        Text(error).foregroundStyle(.secondary)
                    }
                    Button("Use a folder…") { manager.pickFolder(zink: false) }
                }
                Text("The download is compared with the hashes published with the release. That finds a damaged file; it does not prove who made the release.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section2(title: "Actions") {
                ForEach(DriverAction.allCases) { action in
                    ActionRow(action: action, enabled: enabled(action)) {
                        if action.confirms { page.confirming = action } else { manager.perform(action) }
                    }
                }
            }
            if let result = manager.lastResult {
                Text(result).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(page.confirming?.title ?? "", isPresented: Binding(get: { page.confirming != nil }, set: { if !$0 { page.confirming = nil } }), presenting: page.confirming) { action in
            Button(action.title, role: action.destructive ? .destructive : nil) { manager.perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.explanation)
        }
    }

    func enabled(_ action: DriverAction) -> Bool {
        switch action {
        case .check, .install, .repair: return manager.package != nil
        case .undo: return manager.package != nil && manager.facts.hasBackup
        case .uninstall: return manager.package != nil && manager.facts.driverFilesPresent
        }
    }

    var stateText: String {
        switch manager.packageStatus["installed_state"] {
        case "same": return String(localized: "The same")
        case "different": return String(localized: "Different: \(manager.packageStatus["items_different"] ?? "?") item(s)")
        case "partial": return String(localized: "Partly installed")
        case "absent": return String(localized: "Not installed")
        default: return "–"
        }
    }
}

struct ActionRow: View {
    let action: DriverAction
    let enabled: Bool
    let perform: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(action.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action.title, action: perform).disabled(!enabled).fixedSize()
        }
    }
}

struct ZinkView: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        Form {
            Section2(title: "Zink") {
                Text("Optional. LWJGL 3 Java games such as Minecraft render through Mesa's Zink straight to Vulkan, instead of Apple's OpenGL. Native applications stay on Apple's OpenGL.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Installed") { Text(manager.facts.zinkInstalled ? "Yes" : "No") }
                LabeledContent("Every LWJGL application") { Text(manager.facts.zinkGlobal ? "On" : "Off") }
            }
            Section2(title: "Package") {
                if let package = manager.zinkPackage {
                    LabeledContent("Folder") { Text(package.directory.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                }
                HStack {
                    if let release = manager.release, release.asset("-zink-gl.zip") != nil {
                        Button("Download \(release.tag_name)") { Task { await manager.downloadLatest(zink: true) } }
                    } else if manager.release != nil {
                        Text("The latest release has no Zink package.").foregroundStyle(.secondary)
                    }
                    Button("Use a folder…") { manager.pickFolder(zink: true) }
                }
            }
            Section2(title: "Actions") {
                let ready = manager.zinkPackage != nil
                Button(ZinkAction.install.title) { manager.performZink(.install) }.disabled(!ready)
                Button(ZinkAction.test.title) { manager.performZink(.test) }.disabled(!ready || !manager.facts.zinkInstalled)
                if manager.facts.zinkGlobal {
                    Button(ZinkAction.globalOff.title) { manager.performZink(.globalOff) }.disabled(!ready)
                } else {
                    Button(ZinkAction.globalOn.title) { manager.performZink(.globalOn) }.disabled(!ready || !manager.facts.zinkInstalled)
                }
                Text("It applies to applications started afterwards. Running ones must be restarted.").font(.callout).foregroundStyle(.secondary)
                Button(ZinkAction.undo.title, role: .destructive) { manager.performZink(.undo) }.disabled(!ready || !manager.facts.zinkInstalled)
            }
        }
        .formStyle(.grouped)
    }
}

struct LogView: View {
    @EnvironmentObject var manager: Manager
    var body: some View {
        ScrollView {
            Text(manager.log.isEmpty ? String(localized: "Nothing has run yet.") : manager.log)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .defaultScrollAnchor(.bottom)
    }
}
