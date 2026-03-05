import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showInspector = false
    @State private var zoomAction: ZoomAction = .none

    var body: some View {
        HStack(spacing: 0) {
            imageArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                Divider()
                InspectorView(metadata: appState.metadata)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showInspector)
        .toolbar { toolbarContent }
        .navigationTitle(appState.fileURL?.lastPathComponent ?? "NEFViewer")
        .frame(minWidth: 500, minHeight: 350)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .background(keyboardShortcuts)
    }

    // MARK: - Image area

    @ViewBuilder
    private var imageArea: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if appState.isLoading {
                ProgressView()
                    .controlSize(.large)
            } else if appState.image != nil {
                ScrollableImageView(image: appState.image, zoomAction: $zoomAction)
            } else if let error = appState.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(error)
                        .foregroundColor(.secondary)
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Drop a NEF file or click Open")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: { appState.openFilePanel() }) {
                Label("Open", systemImage: "folder")
            }
            .help("Open NEF file…")
        }

        ToolbarItemGroup {
            Button(action: { zoomAction = .zoomOut }) {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom Out")

            Button(action: { zoomAction = .fitToWindow }) {
                Label("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit to Window")

            Button(action: { zoomAction = .zoomIn }) {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom In")
        }

        ToolbarItem {
            Button(action: { showInspector.toggle() }) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    private var keyboardShortcuts: some View {
        Group {
            Button("") { zoomAction = .zoomIn }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { zoomAction = .zoomOut }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { zoomAction = .fitToWindow }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { zoomAction = .actualSize }
                .keyboardShortcut("1", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "nef" else { return }
            Task { @MainActor in
                appState.open(url)
            }
        }
        return true
    }
}
