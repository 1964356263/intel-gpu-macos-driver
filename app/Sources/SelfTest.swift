// SPDX-License-Identifier: MIT
// IntelXeManager --selftest [package folder]: the parts that need no window and no password, for checking a build.
import AppKit
import SwiftUI

/// Each page without a window, to look at the layout.
@MainActor
func renderSnapshots(into folder: String) {
    _ = NSApplication.shared
    let manager = Manager()
    manager.facts = SystemFacts.probe()
    if CommandLine.arguments.count > 2 {
        let package = Package(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        manager.package = package
        manager.packageStatus = package.status()
    }
    if let folder = selfTestEFIFolder, let package = manager.package, let script = efiScript(for: package) {
        manager.efiTarget = .folder(folder)
        manager.efi = efiStatus(script: script, package: package, target: manager.efiTarget)
        for action in [EFIAction.apply, .settings, .undo] {
            manager.efiPlans[action] = efiPlan(script: script, package: package, target: manager.efiTarget, action.planArgument!)
        }
        manager.efiNotice = EFINotice.after(.install, status: manager.efi)
    }
    // the EFI page as it is when OpenCore recorded no boot path: the partitions to choose from
    let choosing = Manager()
    choosing.package = manager.package
    choosing.efi = EFIStatus(text: "efi_source=none\nefi_description=no EFI partition found\nkext_file=unknown\nkext_version_package=0.1.0\n"
        + "candidate=00000000-0000-4000-8000-000000000001|disk0s1|WD Blue SN550 1TB|1000 GB||unknown\n"
        + "candidate=00000000-0000-4000-8000-000000000002|disk5s1|SanDisk Ultra|31 GB|/Volumes/EFI|yes\n")
    choosing.efiNotice = .unchecked
    let pages: [(String, AnyView, CGFloat)] = [
        ("system", AnyView(SystemView().environmentObject(manager)), 640), ("driver", AnyView(DriverView().environmentObject(manager)), 640),
        ("efi", AnyView(EFIView().environmentObject(manager)), 1500), ("efi-choose", AnyView(EFIView().environmentObject(choosing)), 640),
        ("zink", AnyView(ZinkView().environmentObject(manager)), 640), ("banners", AnyView(Banners().environmentObject(choosing).background(Color(nsColor: .windowBackgroundColor))), 120),
    ]
    for (name, page, height) in pages {
        let host = NSHostingView(rootView: page.frame(width: 640, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/\(name).png"))
    }
}

/// The fake EFI the EFI test leaves behind, as stage 1 leaves it, for the EFI page's snapshot.
var selfTestEFIFolder: String?

/// An EFI folder with OpenCore's layout and a config.plist with the parts efi.sh reads, as after stage 1.
func makeFakeEFI(in folder: URL) throws {
    let oc = folder.appendingPathComponent("EFI/OC")
    try FileManager.default.createDirectory(at: oc.appendingPathComponent("Kexts"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: oc.appendingPathComponent("ACPI"), withIntermediateDirectories: true)
    try Data().write(to: oc.appendingPathComponent("OpenCore.efi"))
    let apple = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    let config: [String: Any] = [
        "ACPI": ["Add": [["Comment": "SSDT-EC.aml", "Enabled": true, "Path": "SSDT-EC.aml"]]],
        "Booter": ["Quirks": ["ResizeAppleGpuBars": -1]],
        "Kernel": ["Add": [["Arch": "Any", "BundlePath": "Lilu.kext", "Comment": "", "Enabled": true, "ExecutablePath": "Contents/MacOS/Lilu",
                            "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"]],
                   "Quirks": ["DisableIoMapper": false]],
        "Misc": ["Security": ["ExposeSensitiveData": 6]],
        "NVRAM": ["Add": [apple: ["boot-args": "keepsyms=1", "csr-active-config": Data([0, 0, 0, 0])]], "Delete": [apple: ["boot-args"]]],
        "UEFI": ["Output": ["ReconnectGraphicsOnConnect": false]],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
    try data.write(to: oc.appendingPathComponent("config.plist"))
}

/// efi.sh through the app's own functions against a fake EFI: status, the plan and its hash, apply, the notice after an
/// install (the bug where the app asked to update an EFI kext that was already the package's), undo.
func efiSelfTest(package: Package, expect: (Bool, String) -> Void) {
    guard let script = efiScript(for: package) else { expect(false, "an efi.sh to run"); return }
    print("efi.sh: \(script.path)")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("intelxe-manager-efi-\(getpid())")
    let folder = root.appendingPathComponent("efi")
    do { try makeFakeEFI(in: folder) } catch { expect(false, "fake EFI: \(error)"); return }
    setenv("INTELXE_STATE_DIR", root.appendingPathComponent("state").path, 1)
    setenv("INTELXE_BOOT_PATH", "", 1)
    setenv("INTELXE_CARD_ACPI_PATH", "\\_SB.PC00.PEG1.PEGP", 1)
    let target = EFITarget.folder(folder.path)
    var status = efiStatus(script: script, package: package, target: target)
    expect(status["efi_source"] == "folder" && status.isOpenCore && status["kext_file"] == "absent" && status["kext_entry"] == "absent",
           "efi.sh --status of a fake EFI after stage 1")
    expect(EFINotice.after(.install, status: status) == .kextMissing, "after an install, an EFI without IntelXe.kext is named")
    guard let plan = efiPlan(script: script, package: package, target: target, "--plan") else { expect(false, "efi.sh --plan"); return }
    print(plan.text, terminator: "")
    expect(plan.changes && plan.text.contains("Kernel > Add: add IntelXe.kext"), "the plan adds IntelXe.kext")
    let log = root.appendingPathComponent("efi.log")
    func runEFI(_ argument: String, _ hash: String) -> Bool {
        let words = efiWords(script: script, package: package, target: target, argument) + ["--expect", hash]
        return run(command: words.map(shellQuoted).joined(separator: " "), needsRoot: false, log: log, prompt: "").succeeded
    }
    expect(!runEFI("--apply", String(repeating: "0", count: 64)), "efi.sh refuses a plan that was not the one shown")
    expect(runEFI("--apply", plan.hash), "efi.sh --apply with the hash of the plan the app computed")
    status = efiStatus(script: script, package: package, target: target)
    expect(status["kext_file"] == "same" && status["kext_entry"] == "enabled", "after --apply the EFI's IntelXe.kext is the package's and on")
    expect(EFINotice.after(.install, status: status) == nil, "after an install, no EFI notice when the EFI's IntelXe.kext is the package's")
    let executable = folder.appendingPathComponent("EFI/OC/Kexts/IntelXe.kext/Contents/MacOS/IntelXe")
    if let handle = try? FileHandle(forWritingTo: executable) { handle.seekToEndOfFile(); handle.write(Data("x".utf8)); try? handle.close() }
    status = efiStatus(script: script, package: package, target: target)
    expect(EFINotice.after(.install, status: status) == .kextDiffers, "after an install, a different EFI IntelXe.kext is named")
    if let undo = efiPlan(script: script, package: package, target: target, "--undo-plan") {
        expect(runEFI("--undo", undo.hash), "efi.sh --undo with the hash of its plan")
    } else { expect(false, "efi.sh --undo-plan") }
    status = efiStatus(script: script, package: package, target: target)
    expect(status["kext_file"] == "absent" && status["kext_entry"] == "absent", "after --undo the EFI is as before")
    selfTestEFIFolder = folder.path
}

func selfTest() {
    var failures = 0
    func expect(_ condition: Bool, _ what: String) {
        print(condition ? "ok    \(what)" : "FAIL  \(what)")
        if !condition { failures += 1 }
    }
    expect(Version("v0.1.2")! > Version("0.1.1")!, "0.1.2 is newer than 0.1.1")
    expect(Version("0.10.0")! > Version("0.9.9")!, "versions compare as numbers")
    expect(Version("v0.2") == nil && Version("0.1.x") == nil, "a tag that is not x.y.z is not a version")
    expect(listedHash("abc  a.zip\ndef *b.zip\n", name: "b.zip") == "def", "hash list with the binary mark")
    expect(listedHash("abc  a.zip\n", name: "c.zip") == nil, "a file not in the list has no hash")
    expect(shellQuoted("it's") == "'it'\\''s'", "shell quoting")
    let script = privilegedScript(command: "'/a b/in\"st.sh' --apply", log: "/l.log", prompt: "p")
    expect(script.contains("in\\\"st.sh") && script.hasSuffix("with administrator privileges"), "AppleScript quoting")
    expect(packageSuffix(macOSMajor: 26) == "-tahoe.zip" && packageSuffix(macOSMajor: 15) == "-sequoia.zip" && packageSuffix(macOSMajor: 27) == nil, "package per macOS")

    let parsed = EFIStatus(text: "efi_source=none\nkext_file=unknown\ncandidate=AAAA-1|disk0s1|WD Blue SN550|1000 GB||unknown\ncandidate=BBBB-2|disk3s1|USB|16 GB|/Volumes/EFI|yes\n")
    expect(!parsed.found && parsed.candidates.count == 2 && parsed.candidates[1].mountPoint == "/Volumes/EFI" && parsed.candidates[0].disk == "WD Blue SN550",
           "efi.sh --status with EFI partitions to choose from")
    expect(EFINotice.after(.install, status: parsed) == .unchecked, "after an install, an EFI that could not be read is 'not checked', not 'update it'")
    expect(EFINotice.after(.install, status: EFIStatus(text: "kext_file=same\nkext_entry=enabled")) == nil
           && EFINotice.after(.install, status: EFIStatus(text: "kext_file=different\nkext_entry=enabled")) == .kextDiffers
           && EFINotice.after(.install, status: EFIStatus(text: "kext_file=same\nkext_entry=disabled")) == .kextMissing
           && EFINotice.after(.uninstall, status: EFIStatus(text: "kext_file=same\nkext_entry=disabled")) == nil
           && EFINotice.after(.uninstall, status: EFIStatus(text: "kext_file=same\nkext_entry=enabled")) == .removeKext, "EFI notice after each action")
    expect(EFIPlan(text: "EFI: x\nnothing to change\nnote     y\n").changes == false && EFIPlan(text: "EFI: x\ncopy     z\n").changes, "a plan with and without changes")
    expect(Bundle.main.url(forResource: "efi", withExtension: "sh") != nil, "the app carries efi.sh for packages made before it")

    let sample = #"{"tag_name":"v0.1.2","html_url":"https://example.invalid/r","body":"notes","prerelease":false,"unknown":1,"assets":[{"name":"intel-gpu-macos-driver-0.1.2-tahoe.zip","browser_download_url":"https://example.invalid/a.zip","size":5,"state":"uploaded"},{"name":"intel-gpu-macos-driver-0.1.2.sha256","browser_download_url":"https://example.invalid/s","size":1}]}"#
    let decoded = try? JSONDecoder().decode(Release.self, from: Data(sample.utf8))
    expect(decoded?.version == Version("0.1.2") && decoded?.asset("-tahoe.zip") != nil && decoded?.asset(".sha256") != nil && decoded?.asset("-zink-gl.zip") == nil, "a release as GitHub's API sends it")

    let facts = SystemFacts.probe()
    print("facts macOS \(facts.macOS), \(facts.architecture), card \(facts.hasCard), kext \(facts.kextLoaded), metal '\(facts.metalDevice)', sip '\(facts.sipText)', installed \(facts.installedVersion ?? "-"), zink \(facts.zinkInstalled)/\(facts.zinkGlobal)")
    for check in facts.checks { print("check \(check.id): \(check.state) \(check.value)") }

    if CommandLine.arguments.count > 2 {
        let package = Package(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        expect(package.isValid, "package folder is valid")
        print("status \(package.status().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("intelxe-manager-selftest-\(getpid()).log")
        let ran = run(command: "\(shellQuoted(package.script.path)) --check", needsRoot: false, log: log, prompt: "")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(text.split(separator: "\n").suffix(3).joined(separator: "\n"))
        expect(text.contains("checks") && !ran.cancelled, "ran the package's check and read its log")
        try? FileManager.default.removeItem(at: log)
        efiSelfTest(package: package, expect: expect)
    }

    if let at = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > at + 1 {
        MainActor.assumeIsolated { renderSnapshots(into: CommandLine.arguments[at + 1]) }
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let release = try await latestRelease()
            print("latest \(release.tag_name), assets \(release.assets.map(\.name).joined(separator: " "))")
            expect(release.version != nil, "the latest tag is a version")
        } catch { print("no network answer: \(error.localizedDescription)") }
        semaphore.signal()
    }
    semaphore.wait()
    if let folder = selfTestEFIFolder { try? FileManager.default.removeItem(at: URL(fileURLWithPath: folder).deletingLastPathComponent()) }
    print(failures == 0 ? "selftest passed" : "selftest: \(failures) failure(s)")
    exit(failures == 0 ? 0 : 1)
}
