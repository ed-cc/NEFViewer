import SwiftUI
import NEFViewerCore

struct InspectorView: View {
    let metadata: NEFMetadata?

    var body: some View {
        if let metadata {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoSection(metadata)
                    Divider()
                    shootingSection(metadata)
                }
                .padding()
            }
        } else {
            Text("No metadata")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Info section

    private func infoSection(_ m: NEFMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info")
                .font(.headline)
            metadataRow("Camera", value: m.model.isEmpty ? "—" : m.model)
            metadataRow("Date", value: formattedDate(m.dateTimeOriginal))
        }
    }

    // MARK: - Shooting section

    private func shootingSection(_ m: NEFMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shooting Data")
                .font(.headline)
            metadataRow("ISO", value: m.iso > 0 ? "\(m.iso)" : "—")
            metadataRow("Shutter", value: m.exposureTimeString)
            metadataRow("Aperture", value: m.fNumberString)
            metadataRow("Focal length", value: m.focalLengthString)
        }
    }

    // MARK: - Row

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }

    // MARK: - Date formatting

    private func formattedDate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "—" }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
