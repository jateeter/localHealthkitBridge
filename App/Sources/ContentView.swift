import SwiftUI
import HealthKitBridge
import Darwin

struct ContentView: View {
    @EnvironmentObject private var bridge: BridgeModel
    @StateObject private var mobilePod = MobilePodModel()

    var body: some View {
        TabView {
            PatientMonitorView(mobilePod: mobilePod)
                .tabItem {
                    Label("Patient", systemImage: "heart.text.square")
                }

            BridgeOperationsView(mobilePod: mobilePod)
                .tabItem {
                    Label("Bridge", systemImage: "arrow.triangle.2.circlepath")
                }

            NavigationStack {
                MobilePodManagementView(model: mobilePod)
            }
            .tabItem {
                Label("Pod", systemImage: "lock.shield")
            }
        }
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

    var body: some View {
        NavigationStack {
            List {
                brandingSection
                sourceSection
                managedInformationSection
                actionSection
                dailyTimelineSection
                privacySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Patient Monitor")
            .accessibilityIdentifier("PatientMonitorView")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ownerUtilityMenu
                }
            }
            .refreshable {
                await bridge.refreshStatus()
                await bridge.refreshNotificationStatus()
                await mobilePod.refreshLocalPIMStatus()
            }
        }
    }

    private var ownerUtilityMenu: some View {
        Menu {
            Button {
                Task { await mobilePod.refreshLocalPIMStatus() }
            } label: {
                Label("Refresh PIM Pod status", systemImage: "arrow.clockwise")
            }
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
        } label: {
            Image(systemName: "line.3.horizontal")
                .accessibilityLabel("Owner menu")
        }
        .accessibilityIdentifier("PatientOwnerMenu")
    }

    private var brandingSection: some View {
        Section {
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
                        Text("Monitor and manage your owner-controlled personal health information.")
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
            .padding(.vertical, 6)
        }
    }

    private var sourceSection: some View {
        Section("Information sources") {
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
    }

    private var managedInformationSection: some View {
        Section {
            ForEach(mobilePod.patientMonitorDomains) { domain in
                NavigationLink {
                    PatientDomainGraphView(domainID: domain.id, mobilePod: mobilePod)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: domain.attentionRequired ? "exclamationmark.triangle.fill" : "checkmark.seal")
                            .foregroundStyle(domain.attentionRequired ? .orange : .green)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(domain.title)
                            Text("\(domain.sourceLabel) · FHIR \(domain.fhirResourceType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(domain.itemCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("PatientDomain-\(domain.id)")
            }
        } header: {
            Text("Pod-maintained information")
        } footer: {
            Text("Counts are metadata summaries for owner review. Raw PHI remains inside authenticated owner-controlled flows.")
        }
    }

    private var actionSection: some View {
        Section {
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

            NavigationLink {
                BridgeOperationsView(mobilePod: mobilePod)
            } label: {
                Label("Open HealthKit Bridge controls", systemImage: "arrow.triangle.2.circlepath")
            }

            NavigationLink {
                MobilePodManagementView(model: mobilePod)
            } label: {
                Label("Open Solid Pod management", systemImage: "lock.shield")
            }
        } header: {
            Text("Monitor actions")
        } footer: {
            Text("Notifications are intentionally PHI-safe: they signal that review is available without placing medical details on the lock screen.")
        }
    }

    private var dailyTimelineSection: some View {
        Section {
            WeekdaySelector(selectedWeekday: $selectedWeekday)
            DailyTimelineView(activities: mobilePod.plannedActivities(for: selectedWeekday))
        } header: {
            Text("Daily plan")
        } footer: {
            Text("Default schedule markers are owner-visible planning metadata. The first activity is the morning medication regimen.")
        }
    }

    private var privacySection: some View {
        Section("Owner privacy boundary") {
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
    }
}

private struct PatientDomainGraphView: View {
    let domainID: PatientMonitorDomain.ID
    @ObservedObject var mobilePod: MobilePodModel
    @State private var selectedElementID: PatientSemanticElement.ID?
    @State private var addElement: PatientSemanticElement?

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
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(domain.sourceLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("FHIR \(domain.fhirResourceType)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SemanticSpiderGraphView(
                    domain: domain,
                    selectedElementID: $selectedElementID
                )
                .frame(minHeight: 340)

                SemanticElementSummaryView(
                    domain: domain,
                    element: selectedElement,
                    onAdd: { addElement = selectedElement }
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Management policy")
                        .font(.headline)
                    Text("This screen is an owner-safe summary. Use the Pod tab for Solid paths, mirror status, and consent/audit containers. Use the Bridge tab for HealthKit delivery and Perception Engine status.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(domain.title)
        .onAppear {
            selectedElementID = selectedElementID ?? domain.semanticElements.first?.id
        }
        .sheet(item: $addElement) { element in
            SemanticElementEntryView(domain: domain, element: element, mobilePod: mobilePod)
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
    @ObservedObject var mobilePod: MobilePodModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
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
                Section("Entry") {
                    TextField("Value", text: $value)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
                Section {
                    Button("Stage for owner review") {
                        mobilePod.stageSemanticDatum(domain: domain, element: element, value: value, note: note)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("This stages a durable owner-approved draft in the mobile mirror queue. It does not expose PHI in notifications or logs and does not claim Pod write-through until Solid resource CRUD is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add \(element.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
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
