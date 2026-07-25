import SwiftUI
import HealthKitBridge

struct ContentView: View {
    @EnvironmentObject private var model: BridgeModel
    @StateObject private var mobilePod = MobilePodModel()

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
                Task { await model.sendTestBatch() }
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
