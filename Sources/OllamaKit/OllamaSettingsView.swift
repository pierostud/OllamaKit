import SwiftUI

/// Ready-made settings form for local / cloud Ollama configuration.
///
/// In cloud mode, only models accessible on the account plan are listed
/// (same access-probe + cache approach used in Flashcard).
public struct OllamaSettingsView: View {
    @Bindable private var settings: OllamaSettings

    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var statusMessage = ""
    @State private var installedModels: [OllamaInstalledModel] = []
    @State private var modelsError = ""
    @State private var pullModelName = ""
    @State private var pullProgress: OllamaPullProgress?
    @State private var isBusy = false
    @State private var cloudAccountPlan = ""
    @State private var cloudAccountPlanRaw = ""
    @State private var cloudAccessProgress: (completed: Int, total: Int)?
    @State private var showCloudModelPicker = false

    private enum ConnectionStatus {
        case idle
        case testing
        case connected
        case failed
    }

    public init(settings: OllamaSettings) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "Deployment"),
                    selection: $settings.deploymentMode
                ) {
                    ForEach(OllamaDeploymentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Ollama Deployment")
            } footer: {
                Text(settings.isCloudMode
                     ? String(localized: "Cloud mode connects to ollama.com and lists only models available on your plan.")
                     : String(localized: "Local mode connects to an Ollama server on this Mac or your network."))
                    .font(.caption)
            }

            Section {
                if settings.isCloudMode {
                    SecureField(
                        String(localized: "API Key"),
                        text: $settings.cloudAPIKey
                    )
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                    Link(
                        String(localized: "Create API Key on ollama.com"),
                        destination: URL(string: "https://ollama.com/settings/keys")!
                    )
                    .font(.caption)

                    Text(apiKeyStorageNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField(
                        String(localized: "Base URL"),
                        text: $settings.baseURLString
                    )
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
                }

                HStack {
                    Button(String(localized: "Test Connection")) {
                        Task { await testConnection() }
                    }
                    .disabled(connectionStatus == .testing || isBusy)

                    if connectionStatus == .testing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: statusIconName)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            } header: {
                Text("Configuration")
            }

            Section {
                HStack {
                    Button(String(localized: "Refresh Models")) {
                        Task { await refreshModels(force: true) }
                    }
                    .disabled(isBusy || (settings.isCloudMode && settings.cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let cloudAccessProgress, cloudAccessProgress.total > 0,
                   cloudAccessProgress.completed < cloudAccessProgress.total {
                    ProgressView(
                        value: Double(cloudAccessProgress.completed),
                        total: Double(cloudAccessProgress.total)
                    ) {
                        Text("Checking model access (\(cloudAccessProgress.completed)/\(cloudAccessProgress.total))…")
                    }
                    .font(.caption)
                }

                if !cloudAccountPlan.isEmpty {
                    LabeledContent(String(localized: "Ollama plan")) {
                        Text(cloudAccountPlan)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.isCloudMode {
                    LabeledContent(String(localized: "Model")) {
                        HStack(spacing: 8) {
                            Text(settings.model.isEmpty ? "—" : settings.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(settings.model.isEmpty ? .secondary : .primary)

                            Spacer(minLength: 8)

                            Button(String(localized: "Choose…")) {
                                showCloudModelPicker = true
                            }
                            .disabled(installedModels.isEmpty || isBusy)
                        }
                    }

                    TextField(
                        String(localized: "Model name"),
                        text: $settings.model
                    )
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                    if installedModels.isEmpty {
                        Text(
                            String(localized: "No cloud models available for your plan yet. Add your API key, then refresh.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("\(installedModels.count) models available on your plan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    TextField(
                        String(localized: "Model"),
                        text: $settings.model
                    )
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                    if installedModels.isEmpty {
                        Text(
                            String(localized: "No models found yet. Test the connection, then refresh.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(installedModels) { model in
                            HStack {
                                Button(model.name) {
                                    settings.model = model.name
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                if model.name == settings.model {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }

                                if model.isLoaded {
                                    Text("Loaded")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Button(String(localized: "Stop")) {
                                        Task { await unload(model.name) }
                                    }
                                    .disabled(isBusy)
                                } else {
                                    Button(String(localized: "Load")) {
                                        Task { await load(model.name) }
                                    }
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                }

                if !modelsError.isEmpty {
                    Text(modelsError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(settings.isCloudMode ? String(localized: "Cloud Model") : String(localized: "Models"))
            } footer: {
                if settings.isCloudMode {
                    Text(String(localized: "Only models reachable with your Ollama Cloud plan are shown. Refresh re-checks access."))
                        .font(.caption)
                }
            }

            if !settings.isCloudMode {
                Section {
                    TextField(
                        String(localized: "Model to download"),
                        text: $pullModelName
                    )
                    #if os(macOS)
                    .textFieldStyle(.roundedBorder)
                    #endif

                    Button(String(localized: "Download")) {
                        Task { await pull() }
                    }
                    .disabled(pullModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)

                    if let pullProgress {
                        if let fraction = pullProgress.fractionCompleted {
                            ProgressView(value: fraction) {
                                Text(pullProgress.status)
                                    .font(.caption)
                            }
                        } else {
                            Text(pullProgress.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Download Model")
                } footer: {
                    Link(
                        String(localized: "Browse Ollama Library"),
                        destination: URL(string: "https://ollama.com/library")!
                    )
                    .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showCloudModelPicker) {
            OllamaCloudModelSelectionSheet(
                models: installedModels.map(\.name),
                selection: $settings.model
            )
        }
        .task(id: settings.availabilityToken) {
            await bootstrap(forceRefresh: false)
        }
    }

    private var apiKeyStorageNotice: String {
        #if DEBUG
        String(localized: "Debug build: your API key is stored in UserDefaults.")
        #else
        String(localized: "Your API key is stored securely in the Keychain.")
        #endif
    }

    private var statusIconName: String {
        switch connectionStatus {
        case .connected:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        default:
            return "info.circle"
        }
    }

    private var statusColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private func modelService() -> OllamaModelService {
        OllamaModelService(connectionConfig: settings.connectionConfig)
    }

    private func bootstrap(forceRefresh: Bool) async {
        if settings.isCloudMode,
           !forceRefresh,
           OllamaCloudModelAccessChecker.hasFreshCache(for: settings.cloudAPIKey) {
            loadCachedCloudModels()
            await testConnection(refreshModels: false)
            return
        }

        await testConnection(refreshModels: true)
    }

    private func loadCachedCloudModels() {
        guard let snapshot = OllamaCloudModelAccessChecker.cachedSnapshot(for: settings.cloudAPIKey) else {
            return
        }

        installedModels = snapshot.models.map {
            OllamaInstalledModel(name: $0, isLoaded: false, contextLength: nil)
        }

        if !snapshot.plan.isEmpty {
            cloudAccountPlanRaw = snapshot.plan
            cloudAccountPlan = OllamaCloudAccountInfo(plan: snapshot.plan, email: nil).displayPlan
        }

        ensureSelectedModelIsAvailable()
    }

    private func testConnection(refreshModels shouldRefresh: Bool = true) async {
        connectionStatus = .testing
        statusMessage = String(localized: "Testing…")

        if settings.isCloudMode,
           settings.cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectionStatus = .failed
            statusMessage = String(localized: "An Ollama Cloud API key is required.")
            installedModels = []
            return
        }

        let service = modelService()
        let available = await service.isServerAvailable()

        if available {
            connectionStatus = .connected
            let mode = settings.isCloudMode
                ? String(localized: "Cloud")
                : String(localized: "Local")
            statusMessage = String(localized: "Connected (\(mode))")
            if shouldRefresh {
                await refreshModels(force: true)
            }
        } else {
            connectionStatus = .failed
            statusMessage = settings.isCloudMode
                ? String(localized: "Could not reach Ollama Cloud. Check your API key.")
                : String(localized: "Could not reach the local Ollama server.")
        }
    }

    private func refreshModels(force: Bool) async {
        isBusy = true
        modelsError = ""
        defer {
            isBusy = false
            cloudAccessProgress = nil
        }

        if settings.isCloudMode,
           settings.cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            installedModels = []
            modelsError = String(localized: "An Ollama Cloud API key is required.")
            return
        }

        let service = modelService()

        do {
            var accountPlan: String? = cloudAccountPlanRaw.isEmpty ? nil : cloudAccountPlanRaw

            if settings.isCloudMode {
                if force || cloudAccountPlanRaw.isEmpty {
                    if let info = try? await service.fetchCloudAccountInfo() {
                        cloudAccountPlanRaw = info.plan
                        cloudAccountPlan = info.displayPlan
                        accountPlan = info.plan
                    }
                } else if cloudAccountPlan.isEmpty {
                    cloudAccountPlan = OllamaCloudAccountInfo(plan: cloudAccountPlanRaw, email: nil).displayPlan
                }
            } else {
                cloudAccountPlan = ""
                cloudAccountPlanRaw = ""
                accountPlan = nil
            }

            installedModels = try await service.refreshInstalledModels(
                forceCloudAccessValidation: force && settings.isCloudMode,
                accountPlan: accountPlan,
                onCloudAccessProgress: { completed, total in
                    Task { @MainActor in
                        cloudAccessProgress = (completed, total)
                    }
                }
            )

            ensureSelectedModelIsAvailable()
        } catch {
            modelsError = error.localizedDescription
            installedModels = []
        }
    }

    private func ensureSelectedModelIsAvailable() {
        if !installedModels.contains(where: { $0.name == settings.model }),
           let first = installedModels.first {
            settings.model = first.name
        }
    }

    private func load(_ name: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await modelService().loadModel(name)
            await refreshModels(force: false)
        } catch {
            modelsError = error.localizedDescription
        }
    }

    private func unload(_ name: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await modelService().unloadModel(name)
            await refreshModels(force: false)
        } catch {
            modelsError = error.localizedDescription
        }
    }

    private func pull() async {
        let name = pullModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isBusy = true
        pullProgress = OllamaPullProgress(status: "starting", total: nil, completed: nil)
        defer { isBusy = false }

        do {
            try await modelService().pullModel(name) { progress in
                Task { @MainActor in
                    pullProgress = progress
                }
            }
            settings.model = name
            pullModelName = ""
            pullProgress = nil
            await refreshModels(force: false)
        } catch {
            modelsError = error.localizedDescription
            pullProgress = nil
        }
    }
}
