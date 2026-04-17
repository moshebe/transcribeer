import HighlightedTextEditor
import SwiftUI

/// Manage prompt profiles stored in ~/.transcribeer/prompts/.
///
/// Left pane is the profile list with add / remove controls; right pane is a
/// live-highlighted markdown editor. Changes auto-save after a debounce so
/// the user never has to hunt for a "save" button. The built-in `default`
/// profile maps to `SummarizationService.defaultPrompt` and is read-only.
struct PromptsSettingsView: View {
    @State private var profiles: [String] = []
    @State private var selection: String = PromptProfileManager.defaultName
    @State private var content: String = ""
    @State private var loadedFor: String = ""          // guards against save loops
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var showNewSheet = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            editor
                .frame(minWidth: 360)
        }
        .onAppear { reload() }
        .onDisappear { saveTask?.cancel() }
        .alert(
            "Couldn't save prompt",
            isPresented: errorAlertBinding,
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showNewSheet) {
            NewProfileSheet(existing: profiles) { newName in
                reload(select: newName)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(profiles, id: \.self, selection: $selection) { name in
                ProfileRow(name: name)
                    .tag(name)
            }
            .listStyle(.sidebar)

            Divider()
            sidebarToolbar
        }
        .onChange(of: selection) { _, newSelection in
            loadContent(for: newSelection)
        }
    }

    private var sidebarToolbar: some View {
        HStack(spacing: 0) {
            Button {
                showNewSheet = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New prompt profile")
            .help("New prompt profile…")

            Divider().frame(height: 16)

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!canDeleteSelection)
            .accessibilityLabel("Delete selected profile")
            .help("Delete selected profile")

            Spacer()
        }
        .padding(4)
        .background(.bar)
        .confirmationDialog(
            "Delete \"\(selection)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes ~/.transcribeer/prompts/\(selection).md.")
        }
    }

    private var canDeleteSelection: Bool {
        selection != PromptProfileManager.defaultName && profiles.contains(selection)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            HighlightedTextEditor(text: editorBinding, highlightRules: .markdown)
                .introspect { editor in
                    editor.textView.textContainerInset = NSSize(width: 10, height: 10)
                    editor.textView.font = NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize, weight: .regular
                    )
                }
                .background(Color(nsColor: .textBackgroundColor))

            if selection == PromptProfileManager.defaultName {
                Divider()
                Text("The default prompt is built into the app and can't be edited. " +
                     "Create a new profile to customise it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private var editorHeader: some View {
        HStack {
            Text(selection)
                .font(.headline)
            Spacer()
            if selection != PromptProfileManager.defaultName {
                Text("Saved automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Two-way binding that ignores programmatic loads (to prevent save feedback).
    private var editorBinding: Binding<String> {
        Binding(
            get: { content },
            set: { newValue in
                content = newValue
                guard selection == loadedFor,
                      selection != PromptProfileManager.defaultName else { return }
                scheduleSave(name: selection, content: newValue)
            }
        )
    }

    // Non-optional binding for the alert; clears `errorMessage` on dismiss.
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Actions

    /// Refresh the profile list from disk and optionally move selection to
    /// `select`. Used by the "new profile" flow to highlight the profile that
    /// was just created.
    private func reload(select: String? = nil) {
        profiles = PromptProfileManager.listProfiles()
        if let target = select, profiles.contains(target) {
            selection = target
        } else if !profiles.contains(selection) {
            selection = profiles.first ?? PromptProfileManager.defaultName
        }
        loadContent(for: selection)
    }

    private func loadContent(for name: String) {
        saveTask?.cancel()
        content = name == PromptProfileManager.defaultName
            ? SummarizationService.defaultPrompt
            : PromptProfileManager.readContent(name: name) ?? ""
        loadedFor = name
    }

    private func scheduleSave(name: String, content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try PromptProfileManager.save(name: name, content: content)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func deleteSelection() {
        guard canDeleteSelection else { return }
        let name = selection
        do {
            try PromptProfileManager.delete(name: name)
            selection = PromptProfileManager.defaultName
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Profile row

private struct ProfileRow: View {
    let name: String

    private var isDefault: Bool { name == PromptProfileManager.defaultName }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDefault ? "sparkles" : "doc.text")
                .foregroundStyle(.secondary)
            Text(name)
            if isDefault {
                Spacer()
                Text("built-in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - New profile sheet

/// Modal for creating a new profile. Offers a blank template or one of the
/// curated presets (1:1, standup, sales call, …) so users have a sensible
/// starting point instead of an empty file. The sheet performs the save
/// itself and reports the created name to the parent for selection.
private struct NewProfileSheet: View {
    let existing: [String]
    let onCreate: (_ name: String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var userEditedName = false
    @State private var selectedPresetID = "blank"
    @State private var errorMessage: String?

    private static let blankPresetID = "blank"

    var body: some View {
        VStack(spacing: 0) {
            Text("New prompt profile")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            form

            Divider()
            footer
        }
        .frame(width: 420)
        .onAppear { syncNameFromPreset() }
        .onChange(of: selectedPresetID) { _, _ in syncNameFromPreset() }
        .alert(
            "Couldn't create profile",
            isPresented: errorBinding,
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: nameBinding, prompt: Text("e.g. team-standup"))
            } footer: {
                if let issue = nameIssue {
                    Text(issue).foregroundStyle(.orange).font(.caption)
                } else {
                    Text("Saved as ~/.transcribeer/prompts/\(sanitizedName).md")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Start from") {
                Picker("Template", selection: $selectedPresetID) {
                    Text("Blank").tag(Self.blankPresetID)
                    Divider()
                    ForEach(PromptProfileManager.presets) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)

                if let preset = selectedPreset {
                    Text(preset.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(12)
    }

    // MARK: - Bindings

    /// User edits to `name` set `userEditedName` so subsequent preset changes
    /// don't overwrite what they typed.
    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { newValue in
                name = newValue
                userEditedName = true
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Derived state

    private var selectedPreset: PromptProfileManager.Preset? {
        PromptProfileManager.presets.first { $0.id == selectedPresetID }
    }

    private var presetContent: String {
        selectedPreset?.content ?? ""
    }

    private var sanitizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIssue: String? {
        PromptProfileManager.validationError(for: sanitizedName, existing: existing)
    }

    private var canCreate: Bool {
        !sanitizedName.isEmpty && nameIssue == nil
    }

    // MARK: - Actions

    /// Pre-fill the name with the current preset's id unless the user has
    /// already typed something of their own.
    private func syncNameFromPreset() {
        guard !userEditedName else { return }
        name = selectedPreset?.id ?? ""
    }

    private func create() {
        do {
            try PromptProfileManager.save(name: sanitizedName, content: presetContent)
            onCreate(sanitizedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
