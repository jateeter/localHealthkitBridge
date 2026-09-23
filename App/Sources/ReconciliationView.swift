import SwiftUI

private enum ReconcileState: String, CaseIterable {
    case matched
    case conflict
    case new
    case updated

    var label: String {
        switch self {
        case .matched: return "Matched"
        case .conflict: return "Conflict"
        case .new: return "New"
        case .updated: return "Updated"
        }
    }

    var color: Color {
        switch self {
        case .matched: return Color(red: 0, green: 0.78, blue: 0.70)
        case .conflict: return .orange
        case .new: return .blue
        case .updated: return .yellow
        }
    }
}

private enum ReconcileDecision: String {
    case keepPod
    case useIncoming
    case merge
}

private struct ReconcileDomain: Identifiable {
    let domain: PatientMonitorDomain
    let state: ReconcileState
    let pendingCount: Int
    var id: String { domain.id }
}

struct ReconciliationView: View {
    @ObservedObject var model: MobilePodModel
    @State private var scanned = false
    @State private var selectedDomainID: String?
    @State private var decisions: [String: ReconcileDecision] = [:]
    @State private var showingSummary = false
    @State private var showingSuccess = false

    private var domains: [ReconcileDomain] {
        model.patientMonitorDomains.map { domain in
            let staged = model.stagedData.filter { $0.domainID == domain.id }.count
            let state: ReconcileState
            if domain.attentionRequired {
                state = .conflict
            } else if staged > 0 && domain.itemCount > staged {
                state = .updated
            } else if staged > 0 {
                state = .new
            } else {
                state = .matched
            }
            return ReconcileDomain(domain: domain, state: state, pendingCount: max(staged, domain.attentionRequired ? 1 : 0))
        }
    }

    private var conflicts: [ReconcileDomain] { domains.filter { $0.state == .conflict } }
    private var newDomains: [ReconcileDomain] { domains.filter { $0.state == .new } }
    private var updatedDomains: [ReconcileDomain] { domains.filter { $0.state == .updated } }
    private var resolvedConflicts: Int { conflicts.filter { decisions[$0.id] != nil }.count }
    private var selectedDomain: ReconcileDomain? { domains.first { $0.id == selectedDomainID } }

    var body: some View {
        NavigationStack {
            Group {
                if scanned { resultsView } else { overviewView }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationDestination(isPresented: $showingSummary) { summaryView }
            .navigationDestination(isPresented: $showingSuccess) { successView }
            .sheet(item: Binding(get: { selectedDomain }, set: { selectedDomainID = $0?.id })) { item in
                reviewSheet(item)
            }
        }
        .accessibilityIdentifier("ReconciliationView")
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OCH-RECONCILE ACTIVE")
                        .font(.caption2.bold()).foregroundStyle(Color(red: 0.30, green: 0.48, blue: 0.58))
                    Text("Sync Ledger").font(.largeTitle.bold())
                    Text("Reconcile Apple Health, Epic, and owner-held records to your local Pod")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Text("ACTIVE HEALTH CONNECTIONS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                sourceCard("Apple Health", detail: "Authorized on this device", status: "READY") {
                    scanned = true
                }
                sourceCard("Epic MyChart", detail: "Connected through the local PIM", status: "AVAILABLE") {
                    scanned = true
                }
                sourceCard("Personal Health Pod", detail: "Client-controlled authority", status: model.ownerAccessLabel.uppercased()) {
                    Task { await model.refreshLocalPIMStatus() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ON-DEVICE PRIVACY").font(.caption.bold()).foregroundStyle(.teal)
                    Text("Comparison and owner decisions stay on this device. Clinical values and document contents are not placed in diagnostics or audit summaries.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(16).background(Color.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                Button {
                    scanned = true
                } label: {
                    Label("Scan Records", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
            }
            .padding(16)
        }
        .navigationTitle("Reconcile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner
                Text("RECONCILIATION SEGMENTS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                segmentRow("Exact matches", detail: "Owner-held entries with no pending difference", count: domains.filter { $0.state == .matched }.count, state: .matched)
                segmentRow("Review needed", detail: "Conflicts or duplicate source entries", count: conflicts.count, state: .conflict)
                segmentRow("Newly added", detail: "New owner-staged entries", count: newDomains.count, state: .new)
                segmentRow("Updated", detail: "Existing records with staged changes", count: updatedDomains.count, state: .updated)

                Text("ELEVEN MANAGED DOMAINS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(domains) { item in
                    Button { selectedDomainID = item.id } label: { domainRow(item) }.buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Review progress: \(resolvedConflicts) of \(conflicts.count) conflicts resolved")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ProgressView(value: conflicts.isEmpty ? 1 : Double(resolvedConflicts), total: Double(max(1, conflicts.count)))
                }

                Button("Review & Approve Changes") { showingSummary = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(resolvedConflicts < conflicts.count)
            }
            .padding(16)
        }
        .navigationTitle("Scan Results")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis Complete").font(.headline)
                Text("Eleven domains compared across local sources").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color.teal.opacity(0.7)) }
    }

    private func sourceCard(_ title: String, detail: String, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: action) {
                Label(status, systemImage: "arrow.right.circle.fill")
                    .font(.caption2.bold())
            }
            .buttonStyle(.bordered)
            .tint(.teal)
            .accessibilityLabel("Resolve \(title) status: \(status)")
            .accessibilityIdentifier("ResolveConnectionStatus-\(title)")
        }
        .padding(16).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func segmentRow(_ title: String, detail: String, count: Int, state: ReconcileState) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                selectedDomainID = domains.first(where: { $0.state == state })?.id
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(count)").font(.title3.bold())
                    Label(state.label, systemImage: "arrow.right.circle.fill").font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .tint(state.color)
            .disabled(count == 0)
            .accessibilityLabel("Open \(state.label) resolution queue with \(count) domains")
            .accessibilityIdentifier("ResolveSegmentStatus-\(state.rawValue)")
        }
        .padding(16).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(state == .conflict ? state.color : Color.clear, lineWidth: 1.5) }
    }

    private func domainRow(_ item: ReconcileDomain) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.domain.id)).foregroundStyle(item.state.color).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.domain.title).font(.headline).foregroundStyle(.primary)
                Text("\(item.domain.fhirResourceType) · \(item.domain.sourceLabel)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.state.label.uppercased()).font(.caption2.bold()).foregroundStyle(item.state.color)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reviewSheet(_ item: ReconcileDomain) -> some View {
        NavigationStack {
            Form {
                Section("Record source comparison") {
                    LabeledContent("Domain", value: item.domain.title)
                    LabeledContent("Pod state", value: item.domain.itemCount > 0 ? "Owner-held record" : "No matching record")
                    LabeledContent("Incoming source", value: item.domain.sourceLabel)
                    LabeledContent("Status", value: item.state.label)
                }
                if item.state == .conflict {
                    Section {
                        decisionButton("Keep current Pod state", decision: .keepPod, domainID: item.id)
                        decisionButton("Use incoming source", decision: .useIncoming, domainID: item.id)
                        decisionButton("Merge fields", decision: .merge, domainID: item.id)
                    } header: {
                        Text("Owner decision")
                    } footer: {
                        Text("The decision is staged locally. It does not claim a completed Epic or Pod write.")
                    }
                } else {
                    Section { Text(item.state == .matched ? "No owner action is required." : "This change will be included in the owner approval summary.") }
                }
            }
            .navigationTitle(item.domain.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedDomainID = nil } } }
        }
    }

    private func decisionButton(_ title: String, decision: ReconcileDecision, domainID: String) -> some View {
        Button {
            decisions[domainID] = decision
        } label: {
            HStack { Text(title); Spacer(); if decisions[domainID] == decision { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) } }
        }
    }

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("All conflicts resolved: \(resolvedConflicts) of \(conflicts.count) complete").font(.caption.bold()).foregroundStyle(.secondary)
                ProgressView(value: 1)
                Text("PENDING CHANGES TO POD").font(.caption).foregroundStyle(.secondary)
                summaryLine("New additions", value: "+\(newDomains.count)", color: .blue)
                summaryLine("Updated records", value: "\(updatedDomains.count)", color: .yellow)
                summaryLine("Resolved conflicts", value: "\(resolvedConflicts)", color: .teal)
                summaryLine("Unchanged domains", value: "\(domains.filter { $0.state == .matched }.count)", color: .secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("VERIFIABLE PROVENANCE").font(.caption.bold()).foregroundStyle(.teal)
                    Text("Source and owner-decision metadata remain attached to the local staged transaction. Clinical values are excluded from status and audit summaries.").font(.footnote).foregroundStyle(.secondary)
                }.padding(16).background(Color.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Button("Confirm Owner Approval") {
                    model.approveReconciliationForMirror(resolvedCount: resolvedConflicts, addedCount: newDomains.count, updatedCount: updatedDomains.count)
                    showingSuccess = true
                }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            }.padding(16)
        }
        .background(Color(.systemGroupedBackground)).navigationTitle("Resolution Summary").navigationBarTitleDisplayMode(.inline)
    }

    private func summaryLine(_ title: String, value: String, color: Color) -> some View {
        HStack { Text(title).font(.headline); Spacer(); Text(value).font(.headline.bold()).foregroundStyle(color) }
            .padding(16).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var successView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.teal)
            Text("Reconciliation Approved").font(.title2.bold())
            Text("The owner-approved transaction is queued for authenticated Pod mirroring. No live Epic write is implied.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(model.lastStatusMessage).font(.caption).foregroundStyle(.secondary).padding(16).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
            Button("Done") { showingSuccess = false; showingSummary = false; scanned = false }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(24).navigationTitle("Complete").navigationBarBackButtonHidden()
    }

    private func icon(for domainID: String) -> String {
        switch domainID {
        case "profiles": return "person.crop.circle"
        case "conditions": return "cross.case"
        case "medications": return "pills"
        case "allergies": return "allergens"
        case "immunizations": return "syringe"
        case "vital-signs": return "heart.text.square"
        case "providers": return "stethoscope"
        case "lab-results": return "testtube.2"
        case "insurance-policies": return "shield"
        case "documents": return "doc.text"
        default: return "checklist"
        }
    }
}
