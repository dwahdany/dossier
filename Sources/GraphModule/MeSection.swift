import SwiftUI
import DossierCore

// MARK: - Model

/// Everything the graph states about the owner node, pre-digested for the identity page.
struct MeProfile: Sendable {
    struct Item: Sendable, Identifiable {
        let id: String
        var primary: String
        var secondary: String = ""
        var tag: String?
        var sources: Int64 = 0
        var confidence: Double = 1
        var reference: Int64?
        var sensitivity: Sensitivity = .sensitive
    }

    let info: EntityInfo
    let index: GraphIndex
    let statements: [Statement]
    var names: [Item] = []
    var aliases: [Item] = []
    var handles: [Item] = []
    var places: [Item] = []
    var relationships: [Item] = []
    var family: [Item] = []
    var face: [Item] = []
    var identifiers: [Item] = []
    var facts: [Item] = []
    var sourceRecords: [String] = []
    var languages: [String] = []

    static func load() async throws -> MeProfile {
        let index = try await GraphStore.shared.index()
        guard let owner = index.owner else {
            throw DossierError.message("The graph contains no node marked nm_isCurrentUser, so the system has not identified the owner yet.")
        }
        let detail = try await GraphStore.shared.detail(id: owner.id)
        var p = MeProfile(info: owner, index: index, statements: detail.statements)
        p.sourceRecords = detail.sourceRecords
        let o = index.ontology

        for s in detail.statements {
            let sid = s.id
            switch s.predicate {
            case P.name, P.firstName, P.familyName, P.middleName, P.username, "PS545":
                guard let v = s.simpleValue else { continue }
                p.names.append(Item(id: sid, primary: v, secondary: o.predicateLabel(s.predicate), sources: s.sources, confidence: s.confidence))
            case P.alias:
                guard let alias = s.field(P.alsoKnownAs) else { continue }
                let signal = s.field("nm_signalLabel") ?? ""
                p.aliases.append(Item(id: sid, primary: alias.replacingOccurrences(of: "\t", with: " "), secondary: signal.replacingOccurrences(of: "_", with: " "), sources: s.sources, confidence: Double(s.field("nm_confirmationConfidence") ?? "") ?? s.confidence))
            case P.contact:
                let email = s.field(P.email), phone = s.field(P.phone)
                guard let v = email ?? phone ?? s.fields.first?.object else { continue }
                p.handles.append(Item(id: sid, primary: v, secondary: s.field(P.contactLabel).map(GraphFormat.cleanLabel) ?? "", tag: email != nil ? "e-mail" : (phone != nil ? "phone" : nil), sources: s.sources, confidence: s.confidence))
            case P.url:
                guard let v = s.simpleValue else { continue }
                p.handles.append(Item(id: sid, primary: v, secondary: "", tag: "URL", sources: s.sources, confidence: s.confidence))
            case P.locationRel:
                guard let ref = s.field(P.hasLocation).flatMap(GraphRef.parse) else { continue }
                let place = index.entities[ref]
                p.places.append(Item(id: sid, primary: place?.name ?? "Unknown place", secondary: place?.detail ?? "", tag: s.field(P.personalLabel).map(GraphFormat.cleanLabel), sources: s.sources, confidence: s.confidence, reference: ref))
            case P.association:
                let ref = s.field("nm_personIdentifier").flatMap(GraphRef.parse)
                let label = s.field("nm_unlocalizedRelationshipLabel").map(GraphFormat.cleanLabel) ?? s.field("nm_relationshipLabel") ?? "related"
                let localized = s.field("nm_relationshipLabel") ?? ""
                p.relationships.append(Item(
                    id: sid, primary: ref.flatMap { index.name($0) } ?? "Unknown person",
                    secondary: localized.caseInsensitiveCompare(label) == .orderedSame ? "" : "stored label “\(localized)”",
                    tag: label, sources: s.sources, confidence: Double(s.field("nm_confidence") ?? "") ?? s.confidence, reference: ref))
            case P.visual:
                let reason = (s.field("nm_associationReason") ?? "").replacingOccurrences(of: "association:", with: "")
                p.face.append(Item(id: sid, primary: "Photos person linked", secondary: reason.isEmpty ? "" : "reason: \(reason)", sources: s.sources, confidence: s.confidence, sensitivity: .low))
            case "nm_personType", "nm_photosDetectionType":
                guard let v = s.simpleValue else { continue }
                p.face.append(Item(id: sid, primary: v.capitalized, secondary: o.predicateLabel(s.predicate), sources: s.sources, confidence: s.confidence, sensitivity: .personal))
            case P.identifier:
                let type = s.field(P.identifierType) ?? "identifier"
                let value = s.field(P.identifierID) ?? s.field(P.username) ?? s.field(P.sourceURL) ?? ""
                p.identifiers.append(Item(id: sid, primary: value, secondary: s.field(P.sourceURL) ?? "", tag: type, sources: s.sources, confidence: s.confidence, sensitivity: .personal))
            case "nm_age", "nm_familyMemberType", P.dateOfBirth, "nm_imputedBirthday":
                guard let v = s.simpleValue else { continue }
                p.facts.append(Item(id: sid, primary: index.display(v, predicate: s.predicate), secondary: o.predicateLabel(s.predicate), sources: s.sources, confidence: s.confidence))
            default: break
            }
        }

        // Family circle: group nodes that list the owner as a member.
        let groups = Set(index.edges.filter { $0.predicate == P.groupIncludes && $0.to == owner.id }.map(\.from))
        for g in groups.sorted() {
            for e in index.edges where e.from == g && e.predicate == P.groupIncludes {
                let member = index.entities[e.to]
                p.family.append(Item(
                    id: "fam|\(g)|\(e.to)", primary: member?.name ?? "Unknown member",
                    secondary: e.to == owner.id ? "you" : "", tag: index.entities[g].map { index.ontology.classLabel($0.classID) },
                    sources: index.entities[g]?.sources ?? 0, confidence: index.entities[g]?.confidence ?? 1, reference: e.to))
            }
        }

        p.names.sort { ($0.confidence, $0.primary) > ($1.confidence, $1.primary) }
        p.handles.sort { ($0.tag ?? "", $0.primary) < ($1.tag ?? "", $1.primary) }
        p.languages = (try? await DerivedStore.languages().map { $0.summary }) ?? []
        return p
    }
}

// MARK: - View

/// (1) "Me": the node the system marks as the current user.
struct MeSection: View {
    @Environment(\.refreshToken) private var refreshToken
    @Environment(\.navigate) private var navigate
    @State private var inspected: Int64?

    var body: some View {
        let token = refreshToken
        // Read state here so SwiftUI re-evaluates this body (the content closures below run inside AsyncContent).
        let _ = inspected
        VStack(spacing: 0) {
            AsyncContent(reloadKey: token) {
                await GraphStore.shared.sync(token: token)
                return try await MeProfile.load()
            } content: { profile in
                page(profile)
                    .detailInspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
                        if let inspected {
                            EntityInspector(entityID: inspected, onClose: { self.inspected = nil })
                        }
                    }
            }
            StoreFooter(GraphPaths.graph, note: "stable_graph · node marked nm_isCurrentUser")
        }
    }

    private func page(_ p: MeProfile) -> some View {
        ScrollPage {
            header(p)
            StatTileRow([
                Stat("Statements", Format.count(p.statements.count), caption: "\(Format.count(p.info.rowCount)) graph rows", symbol: "list.bullet.rectangle"),
                Stat("Names & Aliases", Format.count(p.names.count + p.aliases.count), caption: "ways the system can refer to you", symbol: "textformat"),
                Stat("Handles", Format.count(p.handles.count), caption: "e-mail, phone, URLs", symbol: "at", tint: .teal),
                Stat("Relationships", Format.count(p.relationships.count), caption: "declared or inferred", symbol: "heart", tint: .pink),
                Stat("Places", Format.count(p.places.count), caption: "linked locations", symbol: "mappin.and.ellipse", tint: .green),
                Stat("Source Records", Format.count(p.sourceRecords.count), caption: "merged into this node", symbol: "square.stack.3d.up", tint: .orange),
            ])
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 700), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                card("Names", "textformat", "Every name recorded for you, with the systems that supplied it.", p.names, p)
                card("Aliases", "quote.bubble", "Lower-cased tokens Siri and search can use to resolve a mention to you. The signal says how each alias was derived.", p.aliases, p)
                card("Contact Handles", "at", "Addresses and numbers attached to your node.", p.handles, p)
                card("Relationships", "heart", "People linked to you with a relationship label. Labels from your contact card are declared; others are inferred.", p.relationships, p)
                card("Places", "mappin.and.ellipse", "Locations attached to you (addresses on your card, labelled Home / Work).", p.places, p)
                card("Family Circle", "figure.2.and.child.holdinghands", "Members of the Family Sharing group that includes you.", p.family, p)
                card("Face & Age", "face.smiling", "Link to the person Photos recognises as you, plus age facts.", p.face + p.facts, p)
                card("Identifiers", "number", "Record identifiers in other databases that are known to be you.", p.identifiers, p)
            }
            SectionHeader("Every Statement", subtitle: "All \(Format.count(p.statements.count)) statements on your node, grouped by predicate (labels from ontology.db)", symbol: "list.bullet.indent")
            StatementsView(statements: p.statements, index: p.index, onOpen: { inspected = $0 }, collapseAfter: 4)
                .card()
        }
    }

    private func header(_ p: MeProfile) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(initials(p.info.name))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)], startPoint: .top, endPoint: .bottom), in: Circle())
                .sensitive(.sensitive)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(p.info.name).font(.title.weight(.semibold)).textSelection(.enabled).sensitive(.sensitive)
                    SensitivityBadge(.sensitive)
                }
                Text("The node your Mac’s knowledge graph marks as the current user. It merges \(p.sourceRecords.count) records from \(p.index.sources.bits(of: p.info.sources).count) systems into one identity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(p.facts) { fact in
                        HStack(spacing: 3) {
                            Text(fact.secondary.capitalized + ":").foregroundStyle(.secondary)
                            Text(fact.primary).sensitive(.sensitive)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    ForEach(p.languages, id: \.self) { language in
                        HStack(spacing: 3) {
                            Text("Inferred language:").foregroundStyle(.secondary)
                            Text(language).sensitive(.personal)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    SourceBadges(mask: p.info.sources, catalog: p.index.sources, limit: 8)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "?" : s
    }

    private func card(_ title: String, _ symbol: String, _ explanation: String, _ items: [MeProfile.Item], _ p: MeProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text("\(items.count)").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("Nothing recorded on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(14).enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider() }
                        row(item, p)
                    }
                }
                if items.count > 14 {
                    Text("+ \(items.count - 14) more under Every Statement").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card()
    }

    private func row(_ item: MeProfile.Item, _ p: MeProfile) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let ref = item.reference {
                        Button(item.primary) { inspected = ref }
                            .buttonStyle(.link)
                            .font(.callout)
                            .lineLimit(1)
                            .sensitive(item.sensitivity)
                    } else {
                        Text(item.primary).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled).sensitive(item.sensitivity)
                    }
                    if let tag = item.tag, !tag.isEmpty { TagLabel(tag, tint: .accentColor) }
                }
                if !item.secondary.isEmpty {
                    Text(item.secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            SourceBadges(mask: item.sources, catalog: p.index.sources, limit: 2)
            ConfidencePill(value: item.confidence)
        }
        .padding(.vertical, 5)
    }
}
