import SwiftUI
import AppKit

/// Pick a contract, read it on this Mac, and check what it found before
/// anything is created.
///
/// The sheet is the point. The model is good at this and still wrong
/// sometimes, and the output is a client's bill — so every field arrives
/// editable, the schedule is shown in full, and anything the parser refused is
/// listed rather than quietly dropped.
struct ContractImportView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var focus: AppFocus
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .choosing
    @State private var draft = ContractImport.Draft()
    @State private var sourceName = ""

    enum Stage: Equatable {
        case choosing
        case reading
        case review
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch stage {
            case .choosing:  chooser
            case .reading:   reading
            case .review:    review
            case .failed(let message): failure(message)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .frame(maxHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import a contract").font(.headline)
            Text("The contract is read by Apple's model on this Mac. Nothing is "
                 + "uploaded, and nothing is created until you say so.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                choose()
            } label: {
                Label("Choose a PDF…", systemImage: "doc.badge.plus")
            }
            Text("Works on a contract with real text in it. A scanned one is "
                 + "just images, and would need OCR first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading \(sourceName)…")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            Button("Try another file") { stage = .choosing }
        }
    }

    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                SectionHeader("Found in \(sourceName)")

                FormRow(label: "Client") {
                    TextField("Client name", text: $draft.customerName)
                }
                FormRow(label: "Email") {
                    TextField("Billing email", text: $draft.customerEmail)
                }
                FormRow(label: "Project") {
                    TextField("Project name", text: $draft.projectTitle)
                }

                if existingClient != nil {
                    Label("An existing client with this name will be used.",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                SectionHeader(title: "Payment schedule") {
                    Text(Fmt.currency(draft.contractTotal,
                                      code: store.data.business.currencyCode))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if draft.milestones.isEmpty {
                    Text("No payments were found. You can still create the project "
                         + "and add the schedule yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach($draft.milestones) { $milestone in
                        HStack(spacing: 8) {
                            TextField("Deliverable", text: $milestone.deliverable)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DatePicker("", selection: $milestone.dueDate,
                                       displayedComponents: .date)
                                .labelsHidden()
                                .frame(width: 110)
                            DecimalField(placeholder: "0", value: $milestone.amount,
                                         alignment: .trailing)
                                .frame(width: 86)
                            Button(role: .destructive) {
                                draft.milestones.removeAll { $0.id == milestone.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove payment")
                        }
                        Divider()
                    }
                }

                // Anything the parser refused is shown, not swallowed: a line
                // the model mangled is exactly what the user needs to see.
                if !draft.discarded.isEmpty {
                    Divider().padding(.vertical, 4)
                    SectionHeader("Not used")
                    Text("These lines came back without an amount or a date that "
                         + "could be read, so they were left out:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(draft.discarded, id: \.self) { line in
                        Text("· " + line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if stage == .review {
                Text("Check it before creating anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if stage == .review {
                Button("Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.customerName.isEmpty && draft.projectTitle.isEmpty)
            }
        }
    }

    private var existingClient: Customer? {
        let wanted = draft.customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return store.data.customers.first {
            $0.name.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    // MARK: - Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = "Read Contract"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceName = url.lastPathComponent
        stage = .reading

        Task {
            do {
                let text = try ContractImport.text(fromPDF: url)
                let found = try await ContractImport.extract(from: text)
                draft = found
                stage = .review
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    private func create() {
        // Amounts may have been edited in the sheet, so the total is re-summed
        // from what is on screen rather than what the model proposed.
        draft.contractTotal = draft.milestones.reduce(0) { $0 + $1.amount }
        let project = store.importProject(from: draft)
        focus.projectID = project.id
        focus.requestedSection = .projects
        dismiss()
    }
}
