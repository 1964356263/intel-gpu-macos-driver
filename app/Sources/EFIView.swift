// SPDX-License-Identifier: MIT
// The EFI page: stages 2 and 4 of the install guide on the EFI that OpenCore booted from, through efi.sh.
// Every write shows the disk and efi.sh's plan first, and goes through the administrator password dialog.
import AppKit
import SwiftUI

extension EFINotice {
    var text: LocalizedStringKey {
        switch self {
        case .kextDiffers: return "The IntelXe.kext in your EFI differs from this package's. Update it on the EFI page before you restart."
        case .kextMissing: return "Your EFI has no IntelXe.kext, or its config.plist entry is off. Add it on the EFI page before you restart."
        case .unchecked: return "The IntelXe.kext in your EFI could not be checked: the EFI partition is not mounted or was not found. Check it on the EFI page before you restart."
        case .removeKext: return "Remove IntelXe.kext from your EFI before you restart, or macOS comes up without the driver. The EFI page can undo its last change."
        }
    }
}

extension EFIAction {
    var title: String {
        switch self {
        case .mount: return String(localized: "Mount the EFI partition")
        case .apply: return String(localized: "Make these changes")
        case .settings: return String(localized: "Change these settings")
        case .undo: return String(localized: "Undo the last EFI change")
        }
    }
    var explanation: String {
        switch self {
        case .mount: return String(localized: "Mounts the partition so that its files can be read and changed. Nothing is written to it.")
        case .apply, .settings: return String(localized: "Backs up the whole EFI folder first, then makes exactly these changes. If the EFI changed since this list was made, nothing is written. Restart afterwards.")
        case .undo: return String(localized: "Puts back, from the last backup, the files that change replaced. The backup stays. Restart afterwards.")
        }
    }
    var destructive: Bool { self == .undo }
}

final class EFIPageState: ObservableObject {
    @Published var confirming: EFIAction?
}

struct EFIView: View {
    @EnvironmentObject var manager: Manager
    @StateObject var page = EFIPageState()
    var efi: EFIStatus { manager.efi }

    var body: some View {
        Form {
            if manager.package == nil {
                Section2(title: "Package") {
                    Text("Choose a package on the Driver page first: IntelXe.kext and SSDT-ARCOFF.aml come from it.").foregroundStyle(.secondary)
                    Button("Open the Driver page") { manager.requestedSection = .driver }
                }
            } else {
                partition
                if efi.found {
                    files
                    settings
                    undo
                }
            }
            if let result = manager.lastResult {
                Text(result).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $page.confirming) { action in
            EFIConfirmSheet(action: action, plan: manager.efiPlans[action], disk: efi["efi_description"]) { manager.performEFI(action) }
        }
    }

    var partition: some View {
        Section2(title: "EFI partition") {
            Text("For a Mac installed with a plain OpenCore EFI (stage 1 of the install guide): this page does stages 2 and 4 on the EFI that OpenCore booted from, or on an EFI folder you choose, such as a USB stick's.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if manager.efiFolder != nil {
                    Button("Use the EFI partition instead") { manager.useEFIPartition() }
                }
                Spacer()
                Button("Use an EFI folder…") { manager.pickEFIFolder() }
            }
            if !efi.known {
                Text(manager.probing ? String(localized: "Checking…") : "–").foregroundStyle(.secondary)
            } else {
                if efi.found {
                    LabeledContent(LocalizedStringKey(efi["efi_source"] == "folder" ? "Folder" : "Disk")) { Text(diskText).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    if !efi["efi_device"].isEmpty {
                        LabeledContent("Partition") { Text("\(efi["efi_device"]) · \(efi["efi_partition"])").textSelection(.enabled) }
                    }
                    LabeledContent("Found through") { Text(sourceText) }
                    if efi["efi_source"] != "folder" {
                        LabeledContent("Mounted") { Text(efi.mounted ? efi["efi_mount_point"] : String(localized: "No")).textSelection(.enabled) }
                    }
                    LabeledContent("OpenCore") { Text(openCoreText) }
                    if !efi.mounted {
                        Button(EFIAction.mount.title + "…") { page.confirming = .mount }
                    }
                }
                if efi["efi_source"] == "none" || efi["efi_source"] == "chosen" {
                    Text("OpenCore did not record which EFI it booted from (Misc > Security > ExposeSensitiveData without 1). Choose the partition by its disk. The changes below turn that record on for the next boot.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if efi.candidates.isEmpty {
                        Text("No EFI partition found.").foregroundStyle(.secondary)
                    } else {
                        Picker("EFI partition", selection: Binding(get: { manager.efiChoice ?? "" }, set: { manager.chooseEFIPartition($0) })) {
                            Text("Choose…").tag("")
                            ForEach(efi.candidates) { candidate in Text(candidate.label).tag(candidate.uuid) }
                        }
                    }
                }
            }
        }
    }

    var files: some View {
        Section2(title: "IntelXe.kext and SSDT-ARCOFF (stage 4)") {
            LabeledContent("IntelXe.kext in the EFI") { Text(kextText).multilineTextAlignment(.trailing) }
            LabeledContent("Kernel > Add entry") { Text(entryText(efi["kext_entry"])) }
            LabeledContent("SSDT-ARCOFF.aml in the EFI") { Text(fileText(efi["ssdt_file"])) }
            LabeledContent("ACPI > Add entry") { Text(entryText(efi["ssdt_entry"])) }
            LabeledContent("The card's ACPI path") { Text(cardText).textSelection(.enabled).multilineTextAlignment(.trailing) }
            planOrHint(.apply)
            Button(EFIAction.apply.title + "…") { page.confirming = .apply }
                .disabled(!(manager.efiPlans[.apply]?.changes ?? false))
        }
    }

    var settings: some View {
        Section2(title: "Settings (stage 2)") {
            Text("SIP (csr-active-config), the boot-args amfi_get_out_of_my_way=0x1 and intelxe_surfvram=2, ResizeAppleGpuBars, DisableIoMapper and ReconnectGraphicsOnConnect, as stage 2 of the install guide sets them. Separate from the files above; your other settings stay as they are.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            planOrHint(.settings)
            Button(EFIAction.settings.title + "…") { page.confirming = .settings }
                .disabled(!(manager.efiPlans[.settings]?.changes ?? false))
        }
    }

    var undo: some View {
        Section2(title: "Undo") {
            LabeledContent("Last backup") {
                Text(efi.backup.map { "\($0) (\(efi["backup_kind"]))" } ?? String(localized: "None"))
                    .textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            }
            HStack {
                if let backup = efi.backup {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)]) }
                }
                Spacer()
                Button(EFIAction.undo.title + "…", role: .destructive) { page.confirming = .undo }
                    .disabled(efi.backup == nil || !(manager.efiPlans[.undo]?.changes ?? false))
            }
        }
    }

    @ViewBuilder func planOrHint(_ action: EFIAction) -> some View {
        if let plan = manager.efiPlans[action] {
            PlanText(plan: plan)
        } else if !efi.mounted {
            Text("Mount the EFI partition to see what would change.").foregroundStyle(.secondary)
        } else if !efi.isOpenCore {
            Text("This partition has no EFI/OC/OpenCore.efi and config.plist: it is not an OpenCore EFI.").foregroundStyle(.secondary)
        } else if !efi.readable {
            Text("The EFI's config.plist cannot be read.").foregroundStyle(.secondary)
        }
    }

    var diskText: String {
        if efi["efi_source"] == "folder" { return (efi["efi_mount_point"] as NSString).appendingPathComponent("EFI") }
        var parts = [efi["efi_disk"].isEmpty ? String(localized: "Unknown disk") : efi["efi_disk"]]
        switch efi["efi_disk_location"] {
        case "internal": parts.append(String(localized: "internal"))
        case "external": parts.append(String(localized: "external"))
        default: break
        }
        if let bytes = Int64(efi["efi_disk_size"]) { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)) }
        return parts.joined(separator: ", ")
    }

    var sourceText: String {
        switch efi["efi_source"] {
        case "boot-path": return String(localized: "OpenCore's record of this boot")
        case "chosen": return String(localized: "Your choice")
        case "folder": return String(localized: "A folder you chose")
        default: return "–"
        }
    }

    var openCoreText: String {
        switch efi["opencore"] {
        case "yes": return String(localized: "Yes")
        case "no": return String(localized: "No OpenCore here")
        default: return String(localized: "Not checked")
        }
    }

    var kextText: String {
        let package = efi["kext_version_package"], here = efi["kext_version_efi"]
        switch efi["kext_file"] {
        case "same": return String(localized: "The same as the package's (\(package))")
        case "different": return String(localized: "Differs: \(here.isEmpty ? "?" : here) here, \(package) in the package")
        case "absent": return String(localized: "Not there")
        default: return String(localized: "Not checked: the EFI is not mounted")
        }
    }

    func fileText(_ state: String) -> String {
        switch state {
        case "same": return String(localized: "The same as the package's")
        case "different": return String(localized: "Differs from the package's")
        case "absent": return String(localized: "Not there")
        default: return String(localized: "Not checked")
        }
    }

    func entryText(_ state: String) -> String {
        switch state {
        case "enabled": return String(localized: "On")
        case "disabled": return String(localized: "Off")
        case "absent": return String(localized: "Missing")
        default: return "–"
        }
    }

    var cardText: String {
        switch efi["card_acpi_path"] {
        case "": return String(localized: "No Arc B580 found")
        case "none": return String(localized: "The card's port has no ACPI name")
        case let path:
            return efi["ssdt_package_names_card"] == "yes" ? String(localized: "\(path) (the package's table is for it)")
                : String(localized: "\(path) (the package's table is for \\_SB.PC00.PEG1.PEGP)")
        }
    }
}

/// efi.sh's plan as it prints it, without its first line (the EFI, shown above it).
struct PlanText: View {
    let plan: EFIPlan
    var all = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((all ? plan.lines : Array(plan.lines.dropFirst())).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("note ") || line == "nothing to change" ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EFIConfirmSheet: View {
    let action: EFIAction
    let plan: EFIPlan?
    let disk: String
    let confirm: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action.title).font(.title2).bold()
            Label(disk, systemImage: "externaldrive").font(.headline).textSelection(.enabled)
            Text(action.explanation).fixedSize(horizontal: false, vertical: true)
            if let plan {
                ScrollView {
                    PlanText(plan: plan, all: true).padding(8)
                }
                .frame(maxHeight: 280)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("macOS asks for an administrator password next.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action.title, role: action.destructive ? .destructive : nil) {
                    dismiss()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}
