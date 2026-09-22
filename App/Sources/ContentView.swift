import SwiftUI
import HealthKitBridge
import Darwin

private enum OCHTheme {
    static let paper = Color(red: 246 / 255, green: 244 / 255, blue: 236 / 255)
    static let teal = Color(red: 0, green: 200 / 255, blue: 179 / 255)
    static let tealSoft = Color(red: 235 / 255, green: 253 / 255, blue: 249 / 255)
    static let line = Color(red: 220 / 255, green: 227 / 255, blue: 220 / 255)
    static let sage = Color(red: 92 / 255, green: 130 / 255, blue: 113 / 255)
    static let sageSoft = Color(red: 240 / 255, green: 245 / 255, blue: 241 / 255)
    static let blueSoft = Color(red: 226 / 255, green: 235 / 255, blue: 240 / 255)
    static let blueInk = Color(red: 76 / 255, green: 122 / 255, blue: 149 / 255)
}

private struct OCHWellnessPillar: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let domainID: PatientMonitorDomain.ID
    let score: Int?
    let isActive: Bool
}

struct ContentView: View {
    @EnvironmentObject private var bridge: BridgeModel
    @StateObject private var mobilePod = MobilePodModel()

    var body: some View {
        TabView {
            PatientMonitorView(mobilePod: mobilePod)
                .tabItem {
                    Label("Overview", systemImage: "person.fill")
                }

            NavigationStack {
                MobilePodManagementView(model: mobilePod)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
        .tint(OCHTheme.teal)
        .task {
            await bridge.refreshNotificationStatus()
            await mobilePod.refreshLocalPIMStatus()
        }
    }
}

private struct PatientMonitorView: View {
    @EnvironmentObject private var bridge: BridgeModel
    @ObservedObject var mobilePod: MobilePodModel
    @State private var selectedWeekday = Calendar.current.component(.weekday, from: Date())
    @State private var navigationPath: [String] = []

    private var figmaPillars: [OCHWellnessPillar] {
        let domains = Dictionary(uniqueKeysWithValues: mobilePod.patientMonitorDomains.map { ($0.id, $0) })
        func pillar(_ id: String, _ title: String, _ subtitle: String, _ domainID: String, active: Bool = false) -> OCHWellnessPillar {
            let domain = domains[domainID]
            return OCHWellnessPillar(
                id: id,
                title: title,
                subtitle: subtitle,
                domainID: domainID,
                score: active ? Int((domain.map { score(for: $0) } ?? 0.85) * 100) : nil,
                isActive: active
            )
        }
        return [
            pillar("physical", "Physical Health", "Steps, Active Minutes, Heart Rate Variance", "vital-signs", active: true),
            pillar("purpose", "Purpose", "Owner goals and decentralized workflow tasks", "workflow-tasks"),
            pillar("nutrition", "Nutrition", "Nutrition-related laboratory and owner records", "lab-results"),
            pillar("sleep", "Sleep", "Sleep summaries from owner-authorized HealthKit data", "vital-signs"),
            pillar("social", "Social", "Care network and provider relationships", "providers"),
        ]
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    overviewHeader
                    overviewRadarSection
                    clinicalPillarsSection
                    sourceSection
                    actionSection
                    dailyTimelineSection
                    privacySection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 88)
            }
            .background(OCHTheme.paper.ignoresSafeArea())
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("WellnessLandingView")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ownerUtilityMenu
                }
            }
            .navigationDestination(for: String.self) { domainID in
                switch domainID {
                case "bridge-controls":
                    BridgeOperationsView(mobilePod: mobilePod)
                case "pod-management":
                    MobilePodManagementView(model: mobilePod)
                default:
                    if domainID.hasPrefix("pillar:"),
                       let pillar = figmaPillars.first(where: { "pillar:\($0.id)" == domainID }) {
                        PatientDomainGraphView(
                            domainID: pillar.domainID,
                            presentationTitle: pillar.title,
                            presentationSubtitle: pillar.subtitle,
                            mobilePod: mobilePod
                        )
                    } else {
                        PatientDomainGraphView(domainID: domainID, mobilePod: mobilePod)
                    }
                }
            }
            .refreshable {
                await bridge.refreshStatus()
                await bridge.refreshNotificationStatus()
                await mobilePod.refreshLocalPIMStatus()
            }
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OCH-100 CENTRAL")
                .font(.caption2.bold())
                .foregroundStyle(OCHTheme.blueInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OCHTheme.blueSoft, in: RoundedRectangle(cornerRadius: 4))
            Text("Overview")
                .font(.largeTitle.bold())
            Text("Patient-owned decentralized records")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var overviewRadarSection: some View {
        CompactWellnessRadarView(pillars: figmaPillars)
            .frame(height: 236)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("WellnessSpiderGraph")
    }

    private var clinicalPillarsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVE CLINICAL PILLARS")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(figmaPillars) { pillar in
                Button {
                    navigationPath.append("pillar:\(pillar.id)")
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(pillar.isActive ? OCHTheme.teal : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pillar.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(pillar.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let pillarScore = pillar.score {
                            Text("\(pillarScore)")
                                .font(.headline.bold())
                                .foregroundStyle(OCHTheme.teal)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(pillar.isActive ? OCHTheme.teal : OCHTheme.line, lineWidth: pillar.isActive ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("PatientDomain-\(pillar.domainID)")
            }
        }
    }

    private var ownerUtilityMenu: some View {
        Menu {
            Section("Browse records") {
                ForEach(mobilePod.wellnessBrowseDomains) { domain in
                    Button {
                        navigationPath.append(domain.id)
                    } label: {
                        Label(domain.title, systemImage: icon(for: domain.id))
                    }
                    .accessibilityIdentifier("UtilityDomain-\(domain.id)")
                }
            }
            Section("Owner actions") {
                Button {
                    Task { await mobilePod.refreshLocalPIMStatus() }
                } label: {
                    Label("Refresh PIM Pod status", systemImage: "arrow.clockwise")
                }
            }
            Button {
                navigationPath.append("pod-management")
            } label: {
                Label("Solid Pod management", systemImage: "lock.shield")
            }
            Section("Legal") {
                if let termsURL = mobilePod.termsURL {
                    Link(destination: termsURL) {
                        Label("Terms", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("PatientTermsLink")
                }
                if let disclosureURL = mobilePod.dataDisclosureURL {
                    Link(destination: disclosureURL) {
                        Label("Data disclosure", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("PatientDataDisclosureLink")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .accessibilityLabel("Owner menu")
        }
        .accessibilityIdentifier("PatientOwnerMenu")
    }

    private var wellnessHeroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.95), .blue.opacity(0.9)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 31, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenCommons Health")
                        .font(.title3.weight(.semibold))
                    Text("Owner-controlled personal health information, organized by the same Wellness view as the local PIM.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(mobilePod.patientMonitorSummary)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("PatientMonitorSummary")
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var wellnessGraphSection: some View {
        VStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wellness view")
                    .font(.headline)
                Text("Tap a spider-graph node or domain button to monitor and manage that owner-held record domain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WellnessOverviewSpiderGraphView(
                domains: mobilePod.wellnessAxisDomains,
                openDomain: { navigationPath.append($0.id) }
            )
            .frame(height: 310)
            .accessibilityIdentifier("WellnessSpiderGraph")

            WellnessAxisButtonGrid(
                domains: mobilePod.wellnessAxisDomains,
                openDomain: { navigationPath.append($0.id) }
            )
            .frame(maxWidth: .infinity, alignment: .center)

            Text("Profiles, Providers, Insurance, Documents, Workflow Tasks, Terms, and Disclosure are available from the owner menu.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information sources")
                .font(.headline)
            ForEach(mobilePod.patientMonitorSources) { source in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: source.systemImage)
                        .font(.title3)
                        .foregroundStyle(source.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(source.title)
                                .font(.headline)
                            Spacer()
                            Text(source.status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(source.tint)
                        }
                        Text(source.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(source.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("PatientSource-\(source.title)")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monitor actions")
                .font(.headline)
            LabeledContent("Notifications", value: bridge.notificationAuthorizationLabel)
            Button("Enable Patient Monitor notifications") {
                Task { await bridge.requestPatientMonitorNotifications() }
            }
            Button("Send safe monitor notification") {
                Task { await bridge.sendPatientMonitorNotification() }
            }
            Text(bridge.lastNotificationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink(value: "bridge-controls") {
                Label("Open HealthKit Bridge controls", systemImage: "arrow.triangle.2.circlepath")
            }

            NavigationLink(value: "pod-management") {
                Label("Open Solid Pod management", systemImage: "lock.shield")
            }

            Text("Notifications are intentionally PHI-safe: they signal that review is available without placing medical details on the lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var dailyTimelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily plan")
                .font(.headline)
            WeekdaySelector(selectedWeekday: $selectedWeekday)
            DailyTimelineView(activities: mobilePod.plannedActivities(for: selectedWeekday))
            Text("Default schedule markers are owner-visible planning metadata. The first activity is the morning medication regimen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Owner privacy boundary")
                .font(.headline)
            Text("Epic, HealthKit, and Solid Pod information is presented here as operational status and metadata only. Identifiable details stay behind owner authentication, and release workflows remain anonymized unless explicitly approved by the owner.")
                .font(.callout)
            if let termsURL = mobilePod.termsURL {
                Link("Terms and Conditions", destination: termsURL)
                    .accessibilityIdentifier("PatientPrivacyTermsLink")
            }
            if let disclosureURL = mobilePod.dataDisclosureURL {
                Link("Data / Information Disclosure", destination: disclosureURL)
                    .accessibilityIdentifier("PatientPrivacyDisclosureLink")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CompactWellnessRadarView: View {
    let pillars: [OCHWellnessPillar]

    private var globalScore: Int {
        let scores = pillars.compactMap(\.score)
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) * 0.42
                    for fraction in [1.0, 0.7, 0.4] {
                        context.stroke(
                            Path(ellipseIn: CGRect(
                                x: center.x - radius * fraction,
                                y: center.y - radius * fraction,
                                width: radius * fraction * 2,
                                height: radius * fraction * 2
                            )),
                            with: .color(Color.secondary.opacity(0.25)),
                            lineWidth: 1
                        )
                    }

                    guard pillars.count > 2 else { return }
                    var valuePath = Path()
                    for (index, pillar) in pillars.enumerated() {
                        let angle = (Double(index) / Double(pillars.count) * 2 * Double.pi) - (Double.pi / 2)
                        let valueRadius = radius * CGFloat(Double(pillar.score ?? 72) / 100)
                        let point = CGPoint(
                            x: center.x + Darwin.cos(angle) * valueRadius,
                            y: center.y + Darwin.sin(angle) * valueRadius
                        )
                        if index == 0 {
                            valuePath.move(to: point)
                        } else {
                            valuePath.addLine(to: point)
                        }
                    }
                    valuePath.closeSubpath()
                    context.fill(valuePath, with: .color(OCHTheme.teal.opacity(0.2)))
                    context.stroke(valuePath, with: .color(OCHTheme.teal), lineWidth: 2)
                }

                VStack(spacing: 0) {
                    Text("\(globalScore)")
                        .font(.title3.bold())
                    Text("GLOBAL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                .background(Color(.systemBackground), in: Circle())
                .overlay { Circle().stroke(OCHTheme.teal, lineWidth: 1.5) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Global wellness score \(globalScore) out of 100 across \(pillars.count) clinical pillars")
    }
}

private struct WellnessOverviewSpiderGraphView: View {
    let domains: [PatientMonitorDomain]
    let openDomain: (PatientMonitorDomain) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGraph(context: context, size: size)
                }
                .accessibilityElement()
                .accessibilityLabel("Wellness spider graph across \(domains.count) health domains")

                ForEach(Array(domains.enumerated()), id: \.element.id) { index, domain in
                    WellnessDomainNode(domain: domain, action: { openDomain(domain) })
                        .position(nodePosition(in: proxy.size, index: index, count: domains.count))
                }
            }
        }
    }

    private func drawGraph(context: GraphicsContext, size: CGSize) {
        guard domains.count > 2 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.33

        for ring in 1...4 {
            var path = Path()
            let ringRadius = radius * CGFloat(ring) / 4
            for index in domains.indices {
                let point = graphPoint(center: center, radius: ringRadius, index: index, count: domains.count)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
        }

        for (index, domain) in domains.enumerated() {
            let color = color(for: domain.id)
            var axis = Path()
            axis.move(to: center)
            axis.addLine(to: graphPoint(center: center, radius: radius, index: index, count: domains.count))
            context.stroke(axis, with: .color(color.opacity(0.5)), lineWidth: 2)
        }

        var valuePath = Path()
        for (index, domain) in domains.enumerated() {
            let point = graphPoint(center: center, radius: radius * CGFloat(score(for: domain)), index: index, count: domains.count)
            if index == 0 {
                valuePath.move(to: point)
            } else {
                valuePath.addLine(to: point)
            }
        }
        valuePath.closeSubpath()
        context.fill(valuePath, with: .color(.teal.opacity(0.18)))
        context.stroke(valuePath, with: .color(.teal.opacity(0.72)), lineWidth: 2)
    }

    private func nodePosition(in size: CGSize, index: Int, count: Int) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.43
        return graphPoint(center: center, radius: radius, index: index, count: count)
    }

    private func graphPoint(center: CGPoint, radius: CGFloat, index: Int, count: Int) -> CGPoint {
        let angle = (Double(index) / Double(count) * 2 * Double.pi) - (Double.pi / 2)
        return CGPoint(
            x: center.x + (Darwin.cos(angle) * radius),
            y: center.y + (Darwin.sin(angle) * radius)
        )
    }
}

private struct WellnessDomainNode: View {
    let domain: PatientMonitorDomain
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(color(for: domain.id).opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 58, height: 58)
                    Image(systemName: icon(for: domain.id))
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(color(for: domain.id), in: Circle())
                }
                Text(domain.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color(for: domain.id))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(domain.title), \(domain.itemCount) visible records. Open \(domain.title) records.")
        .accessibilityIdentifier("WellnessDomain-\(domain.id)")
    }
}

private struct WellnessAxisButtonGrid: View {
    let domains: [PatientMonitorDomain]
    let openDomain: (PatientMonitorDomain) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 8, alignment: .center),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
            ForEach(domains) { domain in
                Button {
                    openDomain(domain)
                } label: {
                    Label(domain.title, systemImage: icon(for: domain.id))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(color(for: domain.id))
                .accessibilityIdentifier("PatientDomain-\(domain.id)")
            }
        }
        .frame(maxWidth: 500)
    }
}

private func score(for domain: PatientMonitorDomain) -> Double {
    if domain.attentionRequired { return 0.95 }
    if domain.itemCount > 0 { return min(0.95, 0.45 + (Double(domain.itemCount) * 0.12)) }
    return 0.28
}

private func color(for domainID: String) -> Color {
    switch domainID {
    case "vital-signs": return .teal
    case "lab-results": return .blue
    case "medications": return .purple
    case "conditions": return .pink
    case "allergies": return .orange
    case "immunizations": return .green
    case "profiles": return .mint
    case "providers": return .cyan
    case "insurance-policies": return .brown
    case "documents": return .indigo
    case "workflow-tasks": return .yellow
    default: return .teal
    }
}

private func icon(for domainID: String) -> String {
    switch domainID {
    case "vital-signs": return "heart.text.square"
    case "lab-results": return "testtube.2"
    case "medications": return "pills"
    case "conditions": return "stethoscope"
    case "allergies": return "allergens"
    case "immunizations": return "syringe"
    case "profiles": return "person.crop.circle"
    case "providers": return "cross.case"
    case "insurance-policies": return "shield.lefthalf.filled"
    case "documents": return "doc.text"
    case "workflow-tasks": return "checklist"
    default: return "circle.grid.cross"
    }
}

private struct PatientDomainGraphView: View {
    let domainID: PatientMonitorDomain.ID
    var presentationTitle: String? = nil
    var presentationSubtitle: String? = nil
    @ObservedObject var mobilePod: MobilePodModel
    @State private var selectedElementID: PatientSemanticElement.ID?
    @State private var addElement: PatientSemanticElement?
    @State private var lastSavedElementID: PatientSemanticElement.ID?

    private var domain: PatientMonitorDomain {
        mobilePod.patientMonitorDomains.first(where: { $0.id == domainID }) ?? PatientMonitorDomain(
            id: domainID,
            title: domainID,
            fhirResourceType: "Domain",
            sourceLabel: "OpenCommons",
            itemCount: 0,
            attentionRequired: false,
            semanticElements: []
        )
    }

    private var selectedElement: PatientSemanticElement {
        if let selectedElementID,
           let element = domain.semanticElements.first(where: { $0.id == selectedElementID }) {
            return element
        }
        return domain.semanticElements.first ?? PatientSemanticElement(
            id: "summary",
            title: domain.title,
            fhirElement: domain.fhirResourceType,
            sourceLabel: domain.sourceLabel,
            currentSummary: "\(domain.itemCount) owner-visible items",
            statusLabel: domain.attentionRequired ? "Needs review" : "Ready",
            itemCount: domain.itemCount,
            graphValue: 0.5,
            attentionRequired: domain.attentionRequired,
            systemImage: "circle.grid.cross",
            summary: "Domain summary.",
            codingSystemName: nil,
            codingSystemURL: nil,
            codingCode: nil,
            codingDisplay: nil,
            defaultUnit: nil
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if lastSavedElementID != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(OCHTheme.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Record Synced Successfully")
                                .font(.headline)
                            Text("Owner-approved draft updated locally")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(OCHTheme.tealSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(OCHTheme.teal) }
                    .accessibilityIdentifier("RecordSavedBanner")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("CURRENT STATUS")
                        .font(.caption.bold())
                        .foregroundStyle(OCHTheme.teal)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(score(for: domain) * 100))")
                            .font(.system(size: 48, weight: .heavy))
                        Text("/100")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(domain.attentionRequired ? "REVIEW" : "VERIFIED")
                            .font(.caption.bold())
                            .foregroundStyle(domain.attentionRequired ? Color.orange : OCHTheme.teal)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(domain.attentionRequired ? Color.orange.opacity(0.1) : OCHTheme.tealSoft, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text(lastSavedElementID == nil
                         ? "Decentralized storage contains verified data for active clinical sync windows."
                         : "Includes newly self-signed entries recorded just now. The owner review queue has been refreshed.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(OCHTheme.teal) }

                Text("VERIFIED METRICS")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                ForEach(domain.semanticElements) { element in
                    Button {
                        selectedElementID = element.id
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(element.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(element.currentSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if lastSavedElementID == element.id {
                                Text("NEW")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(OCHTheme.teal)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(OCHTheme.tealSoft, in: RoundedRectangle(cornerRadius: 4))
                            }
                            Text(element.statusLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(element.attentionRequired ? Color.orange : OCHTheme.sage)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(OCHTheme.sageSoft, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .padding(16)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(selectedElementID == element.id ? OCHTheme.teal : OCHTheme.line)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("SemanticNode-\(element.id)")
                }

                SemanticElementSummaryView(
                    domain: domain,
                    element: selectedElement,
                    onAdd: { addElement = selectedElement }
                )
            }
            .padding(16)
        }
        .background(OCHTheme.paper.ignoresSafeArea())
        .navigationTitle("\(presentationTitle ?? domain.title) Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedElementID = selectedElementID ?? domain.semanticElements.first?.id
        }
        .sheet(item: $addElement) { element in
            SemanticElementEntryView(
                domain: domain,
                element: element,
                presentationTitle: presentationTitle,
                mobilePod: mobilePod,
                onSaved: { lastSavedElementID = $0 }
            )
        }
    }
}

private struct WeekdaySelector: View {
    @Binding var selectedWeekday: Int

    private let days = Calendar.current.shortWeekdaySymbols.enumerated().map { index, symbol in
        (weekday: index + 1, symbol: symbol)
    }

    var body: some View {
        Picker("Day of week", selection: $selectedWeekday) {
            ForEach(days, id: \.weekday) { day in
                Text(day.symbol).tag(day.weekday)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("DailyTimelineWeekdaySelector")
    }
}

private struct DailyTimelineView: View {
    let activities: [DailyPlannedActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            VStack(spacing: 5) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.35))
                                    .frame(width: 1, height: 24)
                                Text(hourLabel(hour))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42)
                            }
                            .frame(width: 46)
                        }
                    }
                    .padding(.top, 28)

                    ForEach(activities) { activity in
                        ActivityMarker(activity: activity)
                            .offset(x: offset(for: activity), y: 0)
                    }
                }
                .frame(width: 46 * 24, height: 92)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("DailyTimeline")
            }

            ForEach(activities) { activity in
                Label("\(activity.timeLabel) · \(activity.title)", systemImage: activity.systemImage)
                    .font(.caption)
                    .foregroundStyle(activity.tint)
                    .accessibilityIdentifier("DailyActivity-\(activity.id)")
            }
        }
    }

    private func offset(for activity: DailyPlannedActivity) -> CGFloat {
        let hourWidth: CGFloat = 46
        let minuteRatio = CGFloat(activity.minute) / 60
        return (CGFloat(activity.hour) + minuteRatio) * hourWidth
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }
}

private struct ActivityMarker: View {
    let activity: DailyPlannedActivity

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: activity.systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(activity.tint, in: Circle())
            Rectangle()
                .fill(activity.tint)
                .frame(width: 2, height: 54)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activity.title) starts at \(activity.timeLabel)")
    }
}

private struct SemanticSpiderGraphView: View {
    let domain: PatientMonitorDomain
    @Binding var selectedElementID: PatientSemanticElement.ID?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGraph(context: context, size: size)
                }
                .accessibilityElement()
                .accessibilityLabel("\(domain.title) semantic spider graph")
                .accessibilityIdentifier("SemanticSpiderGraph-\(domain.id)")

                ForEach(Array(domain.semanticElements.enumerated()), id: \.element.id) { index, element in
                    SemanticSpiderNode(
                        element: element,
                        isSelected: selectedElementID == element.id,
                        action: { selectedElementID = element.id }
                    )
                    .position(nodePosition(in: proxy.size, index: index, count: domain.semanticElements.count))
                    .onHover { hovering in
                        if hovering {
                            selectedElementID = element.id
                        }
                    }
                }
            }
        }
    }

    private func drawGraph(context: GraphicsContext, size: CGSize) {
        let elements = domain.semanticElements
        guard elements.count > 2 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.34

        for ring in 1...4 {
            var path = Path()
            let ringRadius = radius * CGFloat(ring) / 4
            for index in elements.indices {
                let point = graphPoint(center: center, radius: ringRadius, index: index, count: elements.count)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(.secondary.opacity(0.22)), lineWidth: 1)
        }

        for index in elements.indices {
            var axis = Path()
            axis.move(to: center)
            axis.addLine(to: graphPoint(center: center, radius: radius, index: index, count: elements.count))
            context.stroke(axis, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }

        var valuePath = Path()
        for (index, element) in elements.enumerated() {
            let clampedValue = min(1, max(0.2, element.graphValue))
            let point = graphPoint(center: center, radius: radius * CGFloat(clampedValue), index: index, count: elements.count)
            if index == 0 {
                valuePath.move(to: point)
            } else {
                valuePath.addLine(to: point)
            }
        }
        valuePath.closeSubpath()
        context.fill(valuePath, with: .color(.teal.opacity(0.18)))
        context.stroke(valuePath, with: .color(.teal.opacity(0.75)), lineWidth: 2)
    }

    private func nodePosition(in size: CGSize, index: Int, count: Int) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.43
        return graphPoint(center: center, radius: radius, index: index, count: count)
    }

    private func graphPoint(center: CGPoint, radius: CGFloat, index: Int, count: Int) -> CGPoint {
        let angle = (Double(index) / Double(count) * 2 * Double.pi) - (Double.pi / 2)
        return CGPoint(
            x: center.x + (Darwin.cos(angle) * radius),
            y: center.y + (Darwin.sin(angle) * radius)
        )
    }
}

private struct SemanticSpiderNode: View {
    let element: PatientSemanticElement
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: element.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(isSelected ? Color.teal : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(isSelected ? .white : (element.attentionRequired ? .orange : .teal))
                    .overlay {
                        Circle()
                            .stroke(element.attentionRequired ? Color.orange : Color.teal.opacity(0.45), lineWidth: isSelected ? 3 : 1)
                    }
                Text(element.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 86)
                    .frame(minHeight: 26)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(element.title)
        .accessibilityIdentifier("SemanticNode-\(element.id)")
    }
}

private struct SemanticElementSummaryView: View {
    let domain: PatientMonitorDomain
    let element: PatientSemanticElement
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(element.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(element.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(element.attentionRequired ? .orange : .secondary)
            }

            VStack(spacing: 10) {
                summaryRow("Current", element.currentSummary)
                summaryRow("Summary", element.summary)
                summaryRow("FHIR element", element.fhirElement)
                if let codingSystemName = element.codingSystemName,
                   let codingSystemURL = element.codingSystemURL,
                   let codingCode = element.codingCode {
                    summaryRow("Coding", "\(codingSystemName) \(codingCode)")
                    summaryRow("System URL", codingSystemURL)
                }
                if let codingDisplay = element.codingDisplay {
                    summaryRow("Display", codingDisplay)
                }
                if let defaultUnit = element.defaultUnit {
                    summaryRow("Unit", defaultUnit)
                }
                summaryRow("Source", element.sourceLabel)
                summaryRow("Visible items", "\(element.itemCount)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SemanticElementSummaryTable")

            Button {
                onAdd()
            } label: {
                Label("Add", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("SemanticElementAddButton")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SemanticElementEntryView: View {
    let domain: PatientMonitorDomain
    let element: PatientSemanticElement
    var presentationTitle: String? = nil
    @ObservedObject var mobilePod: MobilePodModel
    let onSaved: (PatientSemanticElement.ID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var note = ""

    private var canSave: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        mobilePod.stageSemanticDatum(domain: domain, element: element, value: value, note: note)
        onSaved(element.id)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Record metric parameters") {
                    TextField(element.defaultUnit.map { "Value (\($0))" } ?? "Value", text: $value)
                    TextField("Owner note", text: $note, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
                Section("Context") {
                    LabeledContent("Domain", value: domain.title)
                    LabeledContent("Element", value: element.title)
                    LabeledContent("FHIR element", value: element.fhirElement)
                    if let codingSystemName = element.codingSystemName,
                       let codingCode = element.codingCode {
                        LabeledContent("Coding", value: "\(codingSystemName) \(codingCode)")
                    }
                    if let codingDisplay = element.codingDisplay {
                        LabeledContent("Display", value: codingDisplay)
                    }
                    if let defaultUnit = element.defaultUnit {
                        LabeledContent("Default unit", value: defaultUnit)
                    }
                }
                Section("Compliance note") {
                    Text("Manual data is locally self-signed before it enters the owner review queue. Authorized clinical peers still require an approved access workflow; this action does not claim direct Pod write-through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OCHTheme.paper)
            .navigationTitle("New \(presentationTitle ?? domain.title) Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Record", systemImage: "checkmark", action: save)
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Stage for owner review")
                        .disabled(!canSave)
                }
            }
        }
        .accessibilityIdentifier("SemanticElementEntryModal")
    }
}

private struct BridgeOperationsView: View {
    @EnvironmentObject private var model: BridgeModel
    @ObservedObject var mobilePod: MobilePodModel

    var body: some View {
        NavigationStack {
            Form {
                settingsSection
                statusSection
                podSection
                healthMetricsSection
                actionsSection
                logSection
            }
            .navigationTitle("HK Bridge")
            .accessibilityIdentifier("BridgeOperationsView")
        }
    }

    private var settingsSection: some View {
        Section("Perception Engine") {
            TextField("PE base URL", text: $model.peBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Bridge ID", text: $model.bridgeId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Bridge token (optional)", text: $model.bridgeToken)
            Button("Apply") { model.applyConfiguration() }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if let status = model.status {
                LabeledContent("Bridge ID", value: status.bridgeId ?? "—")
                LabeledContent("Token required", value: status.tokenConfigured == true ? "yes" : "no")
                LabeledContent("Ingest", value: status.ingestEndpoint ?? "—")
            } else {
                Text(model.statusError ?? "Not fetched yet")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh status") {
                Task { await model.refreshStatus() }
            }
        }
    }

    private var actionsSection: some View {
        Section("HealthKit") {
            Button(model.authorized ? "Authorized ✓" : "Authorize HealthKit") {
                Task { await model.authorize() }
            }
            .disabled(model.authorized)
            Button(model.observing ? "Stop observers" : "Start observers") {
                model.toggleObservers()
            }
            .disabled(!model.authorized)
            Button("Send test batch") {
                Task {
                    await model.sendTestBatch()
                    mobilePod.markBridgeSampleQueued()
                }
            }
        }
    }

    private var healthMetricsSection: some View {
        Section {
            if model.healthMetrics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart.text.square")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No Apple Health metrics yet")
                        .font(.headline)
                    Text(model.healthMetricError ?? "Authorize Apple Health, then refresh to read the latest available summaries.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityIdentifier("HealthMetricsEmptyState")
            } else {
                ForEach(model.healthMetrics) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.family.title)
                                .font(.headline)
                            Spacer()
                            Text(metric.primaryValue)
                                .font(.headline.monospacedDigit())
                        }
                        if let secondary = metric.secondaryValue {
                            Text(secondary)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Label(metric.sourceName ?? "Apple Health", systemImage: metric.isTestData ? "testtube.2" : "heart.fill")
                            Spacer()
                            Text(metric.measuredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("HealthMetric-\(metric.family.rawValue)")
                }
            }

            if let error = model.healthMetricError, !model.healthMetrics.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("HealthMetricError")
            }

            Button {
                Task { await model.refreshHealthMetrics() }
            } label: {
                if model.refreshingHealthMetrics {
                    Label("Refreshing Apple Health…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Refresh Apple Health", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!model.authorized || model.refreshingHealthMetrics)
            .accessibilityIdentifier("RefreshHealthMetricsButton")

            if let refreshedAt = model.healthMetricsRefreshedAt {
                Text("Last queried \(refreshedAt.formatted(date: .abbreviated, time: .shortened)). Values stay on this owner-authorized device except for normalized bridge delivery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let testDate = model.lastTestBatchAt {
                Text("Connectivity test sent \(testDate.formatted(date: .omitted, time: .shortened)); synthetic test values are excluded from the cards above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Apple Health metrics")
        } footer: {
            if !model.healthMetricMissingFamilies.isEmpty {
                Text("No readable recent data: \(model.healthMetricMissingFamilies.map(\.title).joined(separator: ", ")). HealthKit does not disclose whether an individual read permission was denied.")
            }
        }
    }

    private var podSection: some View {
        Section {
            NavigationLink {
                MobilePodManagementView(model: mobilePod)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage owner Pod")
                    Text("Solid sign-in, HealthKit containers, mirror state, and 11 PIM domains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Owner access", value: mobilePod.ownerAccessLabel)
            LabeledContent("Mirror queue", value: mobilePod.mirrorSummary)
        } header: {
            Text("OpenCommons Pod")
        } footer: {
            Text("HealthKitBridge remains the validated RealityEngine ingest path. Pod mirroring UX is staged here for owner-controlled Solid management.")
        }
    }

    private var logSection: some View {
        Section("Sync log") {
            if model.log.isEmpty {
                Text("No events yet").foregroundStyle(.secondary)
            }
            ForEach(model.log) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(color(for: event.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message)
                            .font(.callout)
                        Text(event.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func icon(for kind: SyncEvent.Kind) -> String {
        switch kind {
        case .delivered: return "checkmark.circle"
        case .unmapped: return "questionmark.circle"
        case .failed: return "xmark.circle"
        case .info: return "info.circle"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: SyncEvent.Kind) -> Color {
        switch kind {
        case .delivered: return .green
        case .unmapped: return .orange
        case .failed: return .red
        case .info: return .secondary
        case .alert: return .yellow
        }
    }
}
