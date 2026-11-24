import SwiftUI

/// Every look with a preview and a plain description. Tap one to use it.
/// Shared by the camera's LOOK picker and the editor's Looks tool.
struct FilterGuide: View {
    let thumbnails: [String: UIImage]
    let selectedID: String?
    /// The looks to list.
    var looks: [Look] = Look.all
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Original first, then each named set with a header saying what it is.
                ForEach(looks.filter { $0.id == "none" }) { row($0) }
                ForEach(LookSet.allCases) { set in
                    let inSet = looks.filter { $0.id != "none" && $0.set == set }
                    if !inSet.isEmpty {
                        Section {
                            ForEach(inSet) { row($0) }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.name).font(.system(size: 13, weight: .bold)).foregroundStyle(.yellow)
                                Text(set.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .textCase(nil)
                            .accessibilityIdentifier("guide.set.\(set.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.yellow)
    }

    private func row(_ look: Look) -> some View {
        let selected = (selectedID ?? "none") == look.id
        return Button {
            onPick(look.id == "none" ? nil : look.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                FilterSwatch(image: thumbnails[look.id], selected: selected, side: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(look.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selected ? Color.yellow : Color.primary)
                    Text(look.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.yellow).font(.system(size: 15, weight: .bold))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guide.\(look.id)")
    }
}

/// Square look preview with a yellow ring when selected.
struct FilterSwatch: View {
    let image: UIImage?
    let selected: Bool
    var side: CGFloat = 56

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                .stroke(selected ? Color.yellow : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1)
        )
    }
}
