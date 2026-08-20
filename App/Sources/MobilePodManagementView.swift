import SwiftUI
import MobileSolidCompatModel

struct MobilePodManagementView: View {
    @ObservedObject var model: MobilePodModel

    var body: some View {
        Form {
            connectionSection
            ownerStatusSection
            managedDomainsSection
            containersSection
            legalSection
            privacySection
        }
        .navigationTitle("Pod")
    }

    private var connectionSection: some View {
        Section {
            TextField("Issuer URL", text: $model.issuerURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Storage IRI", text: $model.storageIRI)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("PIM root path", text: $model.pimRootPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Redirect URI", text: $model.redirectURI)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Local PIM base URL", text: $model.localPIMBaseURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Allow insecure local HTTP", isOn: $model.allowInsecureLocalHTTP)
            Button("Save Pod settings") {
                model.saveConfiguration()
            }
            Button("Refresh local PIM/CSS status") {
                Task { await model.refreshLocalPIMStatus() }
            }
        } header: {
            Text("Solid Pod connection")
        } footer: {
            Text("Use localhost/docker CSS settings for MVP review. For physical iPhone testing, set the Local PIM base URL to the notebook LAN address. HTTPS remains required before non-local PHI mirroring.")
        }
    }

    private var ownerStatusSection: some View {
        Section {
            LabeledContent("Owner access", value: model.ownerAccessLabel)
            LabeledContent("DPoP", value: model.session.dpopEnabled ? "Enabled" : "Disabled")
            LabeledContent("Mirror queue", value: model.mirrorSummary)
            if let storageIRI = model.session.storageIRI {
                LabeledContent("Session storage", value: storageIRI)
            }
            if let lastError = model.session.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(model.lastStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Mark HealthKit summaries pending mirror") {
                model.markBridgeSampleQueued()
            }
        } header: {
            Text("Owner access and mirror state")
        } footer: {
            Text("This UX is intentionally token-safe: it shows status, paths, counts, and conflicts without exposing access tokens, refresh tokens, DPoP keys, or raw PHI.")
        }
    }

    private var managedDomainsSection: some View {
        Section {
            ForEach(model.managedDomains) { domain in
                VStack(alignment: .leading, spacing: 3) {
                    Text(domain.displayName)
                    Text("\(domain.apiName) · FHIR \(domain.fhirResourceType)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("OpenCommons Health domains")
        } footer: {
            Text("These match the 11 browser PIM domains managed in the localhost/docker Solid Pod.")
        }
    }

    private var containersSection: some View {
        Section {
            ForEach(model.containers) { container in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: container.mirrorState))
                        .foregroundStyle(color(for: container.mirrorState))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(container.title)
                        Text(container.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(container.purpose)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(container.itemCount)")
                            .font(.headline)
                        Text(label(for: container.mirrorState))
                            .font(.caption2)
                            .foregroundStyle(color(for: container.mirrorState))
                    }
                }
            }
        } header: {
            Text("HealthKit Pod containers")
        }
    }

    private var legalSection: some View {
        Section {
            if let termsURL = model.termsURL {
                Link(destination: termsURL) {
                    Label("Terms and Conditions", systemImage: "doc.text")
                }
                .accessibilityIdentifier("PodTermsLink")
            }
            if let disclosureURL = model.dataDisclosureURL {
                Link(destination: disclosureURL) {
                    Label("Data / Information Disclosure", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("PodDataDisclosureLink")
            }
        } header: {
            Text("Legal and disclosure")
        } footer: {
            Text("Documents are loaded from the configured local PIM stack when reachable, keeping mobile and browser review surfaces aligned.")
        }
    }

    private var privacySection: some View {
        Section {
            Text("Identifiable HealthKit-derived information remains under authenticated owner control. Mirroring to localhost/docker CSS and anonymized release both require explicit owner approval.")
                .font(.callout)
            Text("No Epic, PIM, or Solid credential material is shown in this mobile view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Owner privacy boundary")
        }
    }

    private func icon(for state: MobileSolidMirrorState) -> String {
        switch state {
        case .localOnly: return "iphone"
        case .pendingMirror: return "arrow.triangle.2.circlepath"
        case .mirrored: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .conflict: return "exclamationmark.triangle"
        case .revoked: return "nosign"
        }
    }

    private func color(for state: MobileSolidMirrorState) -> Color {
        switch state {
        case .localOnly: return .secondary
        case .pendingMirror: return .orange
        case .mirrored: return .green
        case .failed: return .red
        case .conflict: return .yellow
        case .revoked: return .red
        }
    }

    private func label(for state: MobileSolidMirrorState) -> String {
        switch state {
        case .localOnly: return "local"
        case .pendingMirror: return "pending"
        case .mirrored: return "mirrored"
        case .failed: return "failed"
        case .conflict: return "conflict"
        case .revoked: return "revoked"
        }
    }
}
