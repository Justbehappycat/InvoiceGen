import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Edits a list of payment methods. Used for the business-wide defaults in
/// Settings and for the per-invoice copy in the invoice editor.
struct PaymentMethodsEditor: View {
    @Binding var methods: [PaymentMethod]
    var showEnableToggles: Bool = true

    @ObservedObject private var lock = PaymentLock.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !lock.isUnlocked {
                lockedView
            } else {
                editor
            }
        }
    }

    private var lockedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(methods) { method in
                HStack(alignment: .top, spacing: 8) {
                    PaymentBadge(method: method, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(method.displayTitle).fontWeight(.medium)
                        ForEach(method.filledFields) { field in
                            Text("\(field.label): \(PaymentLock.mask(field.value))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            if methods.isEmpty {
                Text("No payment methods yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    lock.unlock()
                } label: {
                    Label("Unlock to edit", systemImage: "lock.fill")
                }
                if let failure = lock.lastFailure {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Values are masked and read-only until you authenticate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Unlocked — re-locks after 5 minutes", systemImage: "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Lock now") { lock.lock() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            if methods.isEmpty {
                Text("No payment methods yet — add one and it appears on the invoice under “How to Pay”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach($methods) { $method in
                PaymentMethodRow(
                    method: $method,
                    showEnableToggle: showEnableToggles,
                    onDelete: { methods.removeAll { $0.id == method.id } }
                )
                Divider()
            }

            Menu {
                ForEach(PaymentKind.allCases) { kind in
                    Button(kind.label) { methods.append(.make(kind)) }
                }
            } label: {
                Label("Add payment method", systemImage: "plus")
            }
            .fixedSize()
        }
    }
}

private struct PaymentMethodRow: View {
    @Binding var method: PaymentMethod
    let showEnableToggle: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    pickIcon()
                } label: {
                    PaymentBadge(method: method, size: 22)
                }
                .buttonStyle(.plain)
                .help("Use your own logo image for this method")

                Picker("", selection: Binding(
                    get: { method.kind },
                    set: { newKind in
                        let wasDefaultTitle = method.title.isEmpty || method.title == method.kind.label
                        method.changeKind(to: newKind)
                        if wasDefaultTitle { method.title = newKind.label }
                    }
                )) {
                    ForEach(PaymentKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                TextField("Label shown on the invoice", text: $method.title)

                if method.kind == .bank || method.kind == .wire {
                    Picker("", selection: Binding(
                        get: { method.bankPresetID ?? "" },
                        set: { newValue in
                            method.bankPresetID = newValue.isEmpty ? nil : newValue
                            if let preset = method.bankPreset {
                                if let index = method.fields.firstIndex(where: {
                                    $0.label.caseInsensitiveCompare("Bank") == .orderedSame
                                }), method.fields[index].value.isEmpty {
                                    method.fields[index].value = preset.name
                                }
                                if method.title.isEmpty || method.title == method.kind.label {
                                    method.title = preset.name
                                }
                            }
                        }
                    )) {
                        Text("Generic badge").tag("")
                        ForEach(BankPreset.all) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .help("Badge artwork for common US banks")
                }

                if showEnableToggle {
                    Toggle("Show", isOn: $method.isEnabled)
                        .toggleStyle(.checkbox)
                }

                Menu {
                    if method.iconData != nil {
                        Button("Remove custom logo") { method.iconData = nil }
                    }
                    Button("Choose logo image…") { pickIcon() }
                    Button("Add field") { method.fields.append(PaymentField()) }
                    Button("Delete method", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            ForEach($method.fields) { $field in
                HStack(spacing: 8) {
                    // Required rows keep a fixed label and cannot be removed —
                    // leaving the value blank is fine, losing the field is not.
                    if field.isRequired {
                        Text(field.label)
                            .frame(width: 130, alignment: .leading)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Label", text: $field.label)
                            .frame(width: 130)
                    }

                    TextField(method.kind.hint(for: field.label), text: $field.value)

                    Button {
                        method.fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(field.isRequired)
                    .opacity(field.isRequired ? 0.25 : 1)
                    .help(field.isRequired ? "This field is part of the method and can't be removed" : "Remove field")
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .opacity(method.isEnabled ? 1 : 0.55)
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            method.iconData = data
        }
    }
}
