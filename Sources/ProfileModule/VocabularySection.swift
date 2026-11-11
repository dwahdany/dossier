import SwiftUI
import DossierCore

/// (7) Vocabulary & identifiers: the words the system learned in order to understand the
/// owner (speech recognition, keyboard) and the identifiers / experiment cohorts attached
/// to this user.
struct VocabularySection: View {
    enum Mode: String, CaseIterable, Identifiable {
        case speech = "Speech Vocabulary"
        case phrases = "Shortcuts & Phrases"
        case keyboard = "Keyboard"
        case identifiers = "Identifiers"
        case experiments = "Experiments"
        var id: String { rawValue }
    }

    @State private var mode = Mode.speech
    @Environment(\.deepLink) private var deepLink

    var body: some View {
        // Deep links may set this state before the AsyncContent closure below has ever read it;
        // reading it here keeps the body subscribed (ARCHITECTURE.md §6, AsyncContent).
        let _ = mode
        VStack(spacing: 0) {
            SectionStrip(explanation) {
                ModePicker(modes: Mode.allCases, title: \.rawValue, selection: $mode)
            }
            Group {
                switch mode {
                case .speech: SpeechPage()
                case .phrases: PhrasesTable()
                case .keyboard: KeyboardPage()
                case .identifiers: IdentifiersTable()
                case .experiments: ExperimentsTable()
                }
            }
            .id(mode)
            StoreFooter(footer.0, note: footer.1)
        }
        .onChange(of: deepLink?.nonce, initial: true) {
            guard let link = deepLink, !link.payload.isEmpty else { return }
            let wanted = splitPayload(link.payload).mode.lowercased()
            if let match = Mode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(wanted) }) { mode = match }
        }
    }

    private var explanation: String {
        switch mode {
        case .speech: return "Siri and Dictation build a personal speech profile so they can recognise names they would otherwise mishear: your contacts' first and last names, installed apps, HomeKit rooms and scenes. One profile exists per dictation language."
        case .phrases: return "Phrases apps registered with Siri (shortcut names, chat group names) and your own keyboard text replacements."
        case .keyboard: return "The keyboard's adaptive language model: every word you typed often enough to be remembered, with a usage count. “Learned” words are not in the built-in dictionary — names, jargon, slang."
        case .identifiers: return "Rotating pseudonymous identifiers Siri attaches to analytics uploads, targeting values Trial uses to assign experiments, and your Siri data-sharing choices."
        case .experiments: return "A/B experiments and staged feature rollouts Apple's Trial system enrolled this Mac in. Namespaces name the feature being configured."
        }
    }

    private var footer: (URL, String) {
        switch mode {
        case .speech: return (ProfilePaths.speechProfiles, "SpeechProfile per locale · SpeechMaintenance/ncbvqprofile")
        case .phrases: return (ProfilePaths.customVocabulary, "LatestVocabulary.plist · KeyboardServices/TextReplacements.db")
        case .keyboard: return (ProfilePaths.languageModeling, "<language>-dynamic.lm/dynamic-lexicon.dat")
        case .identifiers: return (Paths.biomeRestrictedStreams, "Siri.AnalyticsIdentifiers.* · Trial kvstore · Siri preferences")
        case .experiments: return (ProfilePaths.trialDB, "experiments · rolloutsV2 · history")
        }
    }
}

// MARK: - Speech vocabulary

private struct SpeechPage: View {
    @State private var category: String?

    var body: some View {
        AsyncContent {
            try SpeechVocabulary.load()
        } isEmpty: { $0.words.isEmpty } content: { data in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $category) {
                        Section("Personal classes") {
                            row(nil, title: "All Words", count: data.words.count, symbol: "square.stack.3d.up")
                            ForEach(data.categories.filter(\.personal)) { item in
                                row(item.category, title: item.title, count: item.count, symbol: symbol(item.category))
                            }
                        }
                        let generic = data.categories.filter { !$0.personal }
                        if !generic.isEmpty {
                            Section("Generic grammar tokens") {
                                ForEach(generic) { item in row(item.category, title: item.title, count: item.count, symbol: "character") }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(data.locales.count) profiles: \(data.locales.joined(separator: ", "))").lineLimit(2)
                        Text("\(Format.bytes(data.profileBytes)) · updated \(DossierDate.relative(data.modified))")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(width: 270)
                Divider()
                let words = category.map { wanted in data.words.filter { $0.category == wanted } } ?? data.words
                PagedTable(
                    rows: words,
                    columns: [
                        PagedColumn<SpeechWord>("Word", width: 280, min: 150, sensitivity: .sensitive) { $0.word }
                            .cell { Text($0.word).font(.callout.weight(.medium)).lineLimit(1) },
                        PagedColumn("Class", width: 210, min: 120) { $0.categoryTitle },
                        PagedColumn("Tag", width: 170, min: 100, monospaced: true, secondary: true) { "\\" + $0.category },
                        PagedColumn("Profiles", width: 220, min: 130, secondary: true) { $0.locales },
                    ],
                    searchPrompt: "Filter vocabulary",
                    reloadKey: category ?? "*",
                    exportName: "speech-vocabulary",
                    emptyTitle: "No Words")
            }
        }
    }

    private func row(_ tag: String?, title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(Format.count(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    private func symbol(_ category: String) -> String {
        if category.hasPrefix("contact") { return "person" }
        if category.hasPrefix("app") { return "app" }
        if category.hasPrefix("company") { return "building.2" }
        if category.hasPrefix("room") || category.hasPrefix("house") || category.hasPrefix("zone") { return "house" }
        if category.hasPrefix("device") || category.hasPrefix("scene") { return "lightbulb" }
        if category == "voice-profile" { return "waveform" }
        return "tag"
    }
}

// MARK: - Shortcuts & phrases

private struct PhrasesTable: View {
    var body: some View {
        AsyncContent(emptyTitle: "No Custom Phrases", emptySymbol: "text.bubble") {
            await CustomVocabulary.all()
        } isEmpty: { $0.isEmpty } content: { rows in
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<CustomPhrase>("Phrase", width: 340, min: 160, sensitivity: .personal) { $0.text }
                        .cell { Text($0.text).font(.callout.weight(.medium)).lineLimit(1) },
                    PagedColumn("Kind", width: 150, min: 100) { $0.kind },
                    PagedColumn("Shortcut", width: 130, min: 130, sensitivity: .personal, monospaced: true) { $0.extra },
                    PagedColumn("Registered By", width: 180, min: 110) { AppNames.name($0.app) },
                    PagedColumn("Updated", width: 150, min: 146) { DossierDate.sortable($0.date) },
                ],
                searchPrompt: "Filter phrases",
                reloadKey: rows.count,
                exportName: "custom-phrases")
        }
    }
}

// MARK: - Keyboard

private struct KeyboardPage: View {
    @State private var language = ""
    @State private var learnedOnly = false

    var body: some View {
        AsyncContent {
            try KeyboardLexicon.load()
        } isEmpty: { $0.words.isEmpty } content: { data in
            let words = data.words
                .filter { (language.isEmpty || $0.language == language) && (!learnedOnly || $0.learned) }
                .sorted { ($0.count, $1.word) > ($1.count, $0.word) }
            VStack(spacing: 0) {
                StatTileRow(stats(data)).padding(Metrics.pagePadding)
                Divider()
                PagedTable(
                    columns: columns,
                    searchPrompt: "Filter words",
                    reloadKey: "\(language)|\(learnedOnly)|\(words.count)",
                    exportName: "keyboard-lexicon",
                    emptyTitle: "No Words",
                    fetch: { [words] req in KeyboardPage.page(words, req) },
                    count: { [words] req in KeyboardPage.filtered(words, req.search).count }
                ) {
                    Picker("Language", selection: $language) {
                        Text("All Languages").tag("")
                        Divider()
                        ForEach(data.languages) { item in Text("\(item.title)  (\(Format.count(item.words)))").tag(item.language) }
                    }
                    .labelsHidden().fixedSize()
                    Toggle("Learned words only", isOn: $learnedOnly).toggleStyle(.checkbox).font(.callout)
                }
            }
        }
    }

    private static func filtered(_ words: [LexiconWord], _ search: String) -> [LexiconWord] {
        guard !search.isEmpty else { return words }
        return words.filter { $0.word.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// In-memory paging with typed sorting (counts and dates sort numerically).
    private static func page(_ words: [LexiconWord], _ request: PageRequest) -> [LexiconWord] {
        var rows = filtered(words, request.search)
        if let sort = request.sort {
            let ascending = sort.ascending
            switch sort.columnID {
            case "word": rows.sort { ($0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending) == ascending }
            case "count": rows.sort { ascending ? $0.count < $1.count : $0.count > $1.count }
            case "language": rows.sort { ascending ? $0.language < $1.language : $0.language > $1.language }
            case "date":
                rows.sort {
                    let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
                    return ascending ? a < b : a > b
                }
            case "learned": rows.sort { ascending ? (!$0.learned && $1.learned) : ($0.learned && !$1.learned) }
            default: break
            }
        }
        guard request.offset < rows.count else { return [] }
        return Array(rows[request.offset..<min(rows.count, request.offset + request.limit)])
    }

    private var columns: [PagedColumn<LexiconWord>] {
        [
            PagedColumn<LexiconWord>("Word", id: "word", width: 320, min: 150, sensitivity: .personal) { $0.word }
                .cell { Text($0.word).font(.callout.weight(.medium)).lineLimit(1) },
            PagedColumn("Times Used", id: "count", width: 90, min: 90, max: 120, alignment: .trailing) { Format.count($0.count) },
            PagedColumn("Language", id: "language", width: 130, min: 130) { ProfileFormat.language($0.language) },
            PagedColumn("Vocabulary", id: "learned", width: 130, min: 130) { $0.learned ? "Learned" : "Built-in" }
                .cell { row in
                    if row.learned { FlagLabel(text: "Learned", symbol: "sparkles", tint: .purple) }
                    else { Text("Built-in").font(.callout).foregroundStyle(.secondary) }
                },
            PagedColumn("Learned On", id: "date", width: 150, min: 146) { $0.date.map { DossierDate.sortable($0) } ?? "" },
        ]
    }

    private func stats(_ data: KeyboardData) -> [Stat] {
        let learned = data.words.filter(\.learned).count
        let top = data.languages.first
        let spelling = data.spellingCounts.first { $0.0 == "total" }?.1
        return [
            Stat("Remembered Words", Format.compact(data.words.count), caption: "\(data.languages.count) languages", symbol: "keyboard", tint: .blue),
            Stat("Learned Words", Format.compact(learned), caption: "outside the dictionary", symbol: "sparkles", tint: .purple),
            Stat("Main Language", top?.title ?? "—", caption: top.map { "\(Format.count($0.words)) words" }, symbol: "globe", tint: .teal),
            Stat("Spell-Checked Words", spelling.map { Format.compact($0) } ?? "—", caption: "running total (Spelling)", symbol: "textformat.abc.dottedunderline", tint: .orange),
        ]
    }
}

// MARK: - Identifiers

private struct IdentifiersTable: View {
    private struct Loaded: Sendable {
        let rows: [IdentifierRow]
        let segments: Int?
    }

    var body: some View {
        AsyncContent {
            Loaded(rows: await IdentifierStore.load(), segments: IdentifierStore.segmentRecords())
        } content: { loaded in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.sequence").foregroundStyle(.secondary)
                    Text(segmentText(loaded.segments)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 34)
                Divider()
                if loaded.rows.isEmpty {
                    StatePlaceholder(title: "No Identifiers", symbol: "number", message: "No Siri analytics identifier streams or Trial targeting values were found on this Mac.")
                } else {
                    PagedTable(
                        rows: loaded.rows,
                        columns: [
                            PagedColumn<IdentifierRow>("Group", width: 130, min: 90) { $0.group },
                            PagedColumn("Identifier", width: 190, min: 130) { $0.name }
                                .cell { Text($0.name).font(.callout.weight(.medium)).lineLimit(1) },
                            PagedColumn("Value", width: 300, min: 160, sensitivity: .sensitive, monospaced: true) { $0.value },
                            PagedColumn("Device", width: 130, min: 130, sensitivity: .personal) { $0.device },
                            PagedColumn("Effective From", width: 150, min: 146) { DossierDate.sortable($0.effective) },
                            PagedColumn("Valid (days)", width: 84, min: 84, alignment: .trailing) { $0.validityDays.map(String.init) ?? "" },
                            PagedColumn("Retired", width: 150, min: 146) { $0.retired.map { DossierDate.sortable($0) } ?? "" },
                            PagedColumn("Recorded", width: 150, min: 146, hiddenByDefault: true) { DossierDate.sortable($0.recorded) },
                        ],
                        searchPrompt: "Filter identifiers",
                        reloadKey: loaded.rows.count,
                        exportName: "identifiers")
                }
            }
        }
    }

    private func segmentText(_ records: Int?) -> String {
        switch records {
        case .none: return "Siri user-segment store (Siri.ODDI.SegmentsCohorts): not present on this Mac."
        case .some(0): return "Siri user-segment store (Siri.ODDI.SegmentsCohorts): present but empty — no cohort assignments recorded."
        case .some(let n): return "Siri user-segment store (Siri.ODDI.SegmentsCohorts): \(Format.count(n)) cohort records — open it in Raw Data › Biome to inspect."
        }
    }
}

// MARK: - Experiments

private struct ExperimentsTable: View {
    @State private var selected: TrialAssignment?

    var body: some View {
        AsyncContent(emptyTitle: "No Experiments", emptySymbol: "flask") {
            try await TrialStore.assignments()
        } isEmpty: { $0.isEmpty } content: { rows in
            PagedTable(
                rows: rows,
                columns: [
                    PagedColumn<TrialAssignment>("Kind", width: 110, min: 104) { $0.kind }
                        .cell { DotLabel(text: $0.kind, color: $0.kind == "Experiment" ? .orange : .blue).font(.callout) },
                    PagedColumn("Feature Namespaces", width: 380, min: 180) { $0.namespaces }
                        .cell { Text($0.namespaces.isEmpty ? "—" : $0.namespaces).font(.callout.weight(.medium)).lineLimit(1) },
                    PagedColumn("Project", width: 220, min: 130, secondary: true) { $0.project },
                    PagedColumn("Status", width: 60, min: 60, alignment: .trailing) { String($0.status) },
                    PagedColumn("Started", width: 150, min: 146) { DossierDate.sortable($0.start) },
                    PagedColumn("Ends", width: 150, min: 146) { $0.end.map { DossierDate.sortable($0) } ?? "" },
                    PagedColumn("Deployment", width: 96, min: 96, alignment: .trailing, secondary: true, hiddenByDefault: true) { String($0.deployment) },
                    PagedColumn("Identifier", width: 220, min: 130, monospaced: true, secondary: true, hiddenByDefault: true) { $0.identifier },
                ],
                searchPrompt: "Filter experiments",
                reloadKey: rows.count,
                exportName: "trial-assignments",
                onSelect: { selection in selected = selection.count == 1 ? selection.first : nil }
            )
            .detailInspector(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                if let selected { inspector(selected) }
            }
        }
    }

    private struct Detail: Sendable {
        let history: [TrialEvent]
        let activation: [(String, String)]
    }

    @ViewBuilder private func inspector(_ item: TrialAssignment) -> some View {
        InspectorPage(title: item.namespaces.isEmpty ? item.identifier : item.namespaces, subtitle: item.kind, onClose: { selected = nil }) {
            KeyValueGrid([
                KeyValueItem("Kind", item.kind == "Experiment" ? "Experiment (A/B test)" : "Rollout (staged feature release)"),
                KeyValueItem("Namespaces", item.namespaces),
                KeyValueItem("Project", item.project.isEmpty ? nil : item.project),
                KeyValueItem("Identifier", item.identifier, monospaced: true),
                KeyValueItem("Deployment", String(item.deployment)),
                KeyValueItem(item.kind == "Experiment" ? "Treatment" : "Factor pack", item.treatment.isEmpty ? nil : item.treatment, monospaced: true),
                KeyValueItem("Status code", String(item.status)),
                KeyValueItem(item.kind == "Experiment" ? "Starts" : "First seen", DossierDate.medium(item.start)),
                KeyValueItem("Ends", item.end.map { DossierDate.medium($0) }),
            ])
            Text("Status and event codes are shown as stored; Apple does not document their meaning.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            AsyncContent(reloadKey: item.id) {
                Detail(history: await TrialStore.history(item), activation: await TrialStore.activation(item))
            } content: { detail in
                VStack(alignment: .leading, spacing: 16) {
                    if !detail.activation.isEmpty {
                        InspectorGroupTitle("Reported at activation")
                        KeyValueGrid(detail.activation.enumerated().map { KeyValueItem($0.element.0, $0.element.1, id: "a\($0.offset)") })
                    }
                    if !detail.history.isEmpty {
                        InspectorGroupTitle("History (\(detail.history.count) events)")
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(detail.history) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(DossierDate.sortable(event.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text("event \(event.type)").font(.caption)
                                    Text(event.detail).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 60)
        }
    }
}
