import SwiftUI

/// Searchable sheet for picking an accessible Ollama Cloud model.
public struct OllamaCloudModelSelectionSheet: View {
    let models: [String]
    @Binding var selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    public init(models: [String], selection: Binding<String>) {
        self.models = models
        self._selection = selection
    }

    private var filteredModels: [String] {
        guard !searchText.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        NavigationStack {
            Group {
                if models.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Models"),
                        systemImage: "cloud",
                        description: Text(String(localized: "Refresh the model list after configuring your API key."))
                    )
                } else if filteredModels.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredModels, id: \.self) { name in
                        Button {
                            selection = name
                            dismiss()
                        } label: {
                            HStack {
                                Text(name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if name == selection {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "Search cloud models"))
            .navigationTitle(String(localized: "Cloud Models"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}
