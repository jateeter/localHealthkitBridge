import SwiftUI
import HealthKitBridge

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
        }
    }
}

private struct PatientMonitorView: View {
    @EnvironmentObject private var bridge: BridgeModel
    @ObservedObject var mobilePod: MobilePodModel

    var body: some View {
        NavigationStack {
            List {
                brandingSection
                sourceSection
                managedInformationSection
                actionSection
                privacySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Patient Monitor")
            .accessibilityIdentifier("PatientMonitorView")
            .refreshable {
                await bridge.refreshStatus()
                await bridge.refreshNotificationStatus()
            }
        }
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
                    PatientDomainDetailView(domain: domain)
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

    private var privacySection: some View {
        Section("Owner privacy boundary") {
            Text("Epic, HealthKit, and Solid Pod information is presented here as operational status and metadata only. Identifiable details stay behind owner authentication, and release workflows remain anonymized unless explicitly approved by the owner.")
                .font(.callout)
        }
    }
}

private struct PatientDomainDetailView: View {
    let domain: PatientMonitorDomain

    var body: some View {
        Form {
            Section("Domain") {
                LabeledContent("Name", value: domain.title)
                LabeledContent("FHIR resource", value: domain.fhirResourceType)
                LabeledContent("Current source", value: domain.sourceLabel)
                LabeledContent("Visible items", value: "\(domain.itemCount)")
                LabeledContent("Needs review", value: domain.attentionRequired ? "Yes" : "No")
            }
            Section("Management policy") {
                Text("This screen is an owner-safe summary. Use the Pod tab for Solid paths, mirror status, and consent/audit containers. Use the Bridge tab for HealthKit delivery and Perception Engine status.")
                    .font(.callout)
            }
        }
        .navigationTitle(domain.title)
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
