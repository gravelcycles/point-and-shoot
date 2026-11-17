import SwiftUI

/// The whole library, by day. Tap a photo to jump the viewer to it, or Select to pick
/// several and export, share, keep, paste a grade onto or trash them together. The Trash
/// (shots deleted, or past their 30 days) is one tap away.
struct RollGrid: View {
    let store: ShotStore
    let camera: CameraController
    let onSelect: (Shot) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var share: ShareItem?
    @State private var working = false
    @State private var message: String?
    @State private var showTrash = false
    @State private var confirmArchive = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    private var selectedShots: [Shot] { store.shots.filter { selected.contains($0.id) } }

    struct DayGroup: Identifiable {
        let day: Date
        var shots: [Shot]
        var id: Date { day }
    }

    /// Shots grouped by calendar day, newest day first.
    private var days: [DayGroup] {
        let cal = Calendar.current
        var out: [DayGroup] = []
        for shot in store.shots {
            let day = cal.startOfDay(for: shot.captured)
            if out.last?.day == day { out[out.count - 1].shots.append(shot) } else { out.append(DayGroup(day: day, shots: [shot])) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { group in
                        Section {
                            ForEach(group.shots) { shot in cell(shot) }
                        } header: {
                            Text(dayTitle(group.day))
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.bar)
                        }
                    }
                }
            }
            .overlay {
                if store.isLoaded && store.shots.isEmpty {
                    ContentUnavailableView("No photos", systemImage: "photo.on.rectangle",
                                           description: Text(store.trash.isEmpty ? "Shots you take appear here." : "Deleted shots are in the Trash."))
                }
            }
            .overlay(alignment: .topLeading) { RollCountProbe(store: store) }
            .overlay(alignment: .bottom) {
                if let message {
                    Toast(text: message).padding(.bottom, selecting ? 70 : 20)
                        .transition(.opacity)
                }
            }
            .navigationTitle(selecting ? (selected.isEmpty ? "Select Items" : "\(selected.count) Selected") : "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .onChange(of: store.shots.map(\.id)) { _, ids in
                // Trashed elsewhere (or by the 30-day sweep): drop it from the selection.
                selected.formIntersection(ids)
            }
            // One presentation per anchor view.
            .background {
                Color.clear.sheet(item: $share) { item in
                    ActivityView(items: item.urls).presentationDetents([.medium, .large]).ignoresSafeArea()
                }
                Color.clear.sheet(isPresented: $showTrash) { TrashView(store: store) }
            }
            .confirmationDialog(selected.count == 1 ? "Archive 1 RAW Photo" : "Archive \(selected.count) RAW Photos",
                                isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Save to Photo Library") { archiveToPhotos() }
                Button("Save or Share Zip…") { archiveZip() }
            } message: {
                Text("Saves the original RAW files. A zip also includes each photo's grade, and Import Archive in Preferences brings it back.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func cell(_ shot: Shot) -> some View {
        let isSelected = selected.contains(shot.id)
        return ShotThumbnail(shot: shot, store: store)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if shot.keep && !selecting {
                    Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Color.tan)
                        .padding(4).shadow(radius: 2)
                }
            }
            .overlay {
                if store.developing.contains(shot.id) {
                    ProgressView().tint(.white).controlSize(.small)
                }
                if selecting {
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.opacity(isSelected ? 0.3 : 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(isSelected ? Color.black : Color.white,
                                             isSelected ? Color.tan : Color.black.opacity(0.3))
                            .padding(5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { tap(shot) }
            .accessibilityElement()
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("grid.cell")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selecting {
                Button("Cancel") { selecting = false; selected = [] }
                    .accessibilityIdentifier("grid.cancel")
            } else {
                Button { showTrash = true } label: {
                    Label("Trash", systemImage: "trash")
                }
                .accessibilityIdentifier("grid.trash")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button(selected.count == store.shots.count ? "Deselect All" : "Select All") {
                    selected = selected.count == store.shots.count ? [] : Set(store.shots.map(\.id))
                }
            } else {
                HStack {
                    Button("Select") { selecting = true }
                        .disabled(store.shots.isEmpty)
                        .accessibilityIdentifier("grid.select")
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 22) {
            Text(selected.count == 1 ? "1 photo" : "\(selected.count) photos")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Button { export() } label: { Image(systemName: "square.and.arrow.down") }
                .accessibilityIdentifier("grid.export")
            Button { shareSelected() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityIdentifier("grid.share")
            Menu {
                Button { store.setKeep(true, for: Array(selected)) } label: { Label("Keep", systemImage: "bookmark") }
                Button { store.setKeep(false, for: Array(selected)) } label: { Label("Don't Keep", systemImage: "bookmark.slash") }
                Divider()
                Button { confirmArchive = true } label: { Label("Archive RAW…", systemImage: "archivebox") }
                    .accessibilityIdentifier("grid.archive")
                Divider()
                Button {
                    if let first = selectedShots.first { EditClipboard.recipe = store.recipe(for: first.id) }
                } label: { Label("Copy Grade", systemImage: "doc.on.doc") }
                .disabled(selected.count != 1)
                Button {
                    guard let copied = EditClipboard.recipe else { return }
                    for shot in selectedShots {
                        store.setRecipe(copied.look(appliedTo: store.recipe(for: shot.id)), for: shot.id)
                    }
                    flash("Grade pasted onto \(selected.count)")
                } label: { Label("Paste Grade", systemImage: "doc.on.clipboard") }
                .disabled(EditClipboard.recipe == nil)
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityIdentifier("grid.more")
            Button(role: .destructive) { trashSelected() } label: { Image(systemName: "trash") }
                .tint(.red)
                .accessibilityIdentifier("grid.delete")
        }
        .font(.system(size: 19))
        .disabled(selected.isEmpty || working)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }

    private func tap(_ shot: Shot) {
        if selecting {
            if selected.contains(shot.id) { selected.remove(shot.id) } else { selected.insert(shot.id) }
            Haptics.selectionChanged()
        } else {
            onSelect(shot)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { message = nil }
        }
    }

    private func trashSelected() {
        let ids = Array(selected)
        store.moveToTrash(ids)
        selected = []
        selecting = false
        Haptics.impact(.light)
        flash(ids.count == 1 ? "Moved to Trash" : "\(ids.count) moved to Trash")
    }

    private func export() {
        let shots = selectedShots
        working = true
        Task {
            do {
                let n = try await ShotExporter.exportToPhotos(shots, store: store, options: .init(camera.settings))
                Haptics.success()
                flash(n == 1 ? "Saved to Photos" : "\(n) saved to Photos")
                selecting = false
                selected = []
            } catch {
                flash("Couldn't save to Photos: \(error.localizedDescription)")
            }
            working = false
        }
    }

    private func archiveToPhotos() {
        let shots = selectedShots
        working = true
        Task {
            do {
                let n = try await ShotArchive.archiveToPhotos(shots, store: store)
                flash(n == 1 ? "1 RAW photo added to Photos" : "\(n) RAW photos added to Photos")
            } catch {
                flash("Couldn't archive: \(error.localizedDescription)")
            }
            working = false
        }
    }

    private func archiveZip() {
        let shots = selectedShots
        working = true
        Task {
            do {
                let url = try await ShotArchive.makeZip(shots, store: store)
                share = ShareItem(url: url)
            } catch {
                flash("Couldn't make the zip: \(error.localizedDescription)")
            }
            working = false
        }
    }

    private func shareSelected() {
        let shots = selectedShots
        working = true
        Task {
            let urls = await ShotExporter.shareFiles(shots, store: store, options: .init(camera.settings))
            working = false
            if !urls.isEmpty { share = ShareItem(urls: urls) }
        }
    }
}

/// Shots deleted, or past their 30 days without Keep. Each stays 30 days, then it's gone.
struct TrashView: View {
    let store: ShotStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Photos here are deleted for good 30 days after they were moved to the Trash. Tap one to put it back.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(store.trash) { shot in
                        ShotThumbnail(shot: shot, store: store)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .overlay(alignment: .bottomLeading) {
                                if let t = shot.trashedAt {
                                    let left = max(0, ShotRetention.trashDays - Int(Date().timeIntervalSince(t) / 86_400))
                                    Text("\(left)d").font(.system(size: 10, weight: .bold)).padding(4)
                                        .shadow(radius: 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.restore([shot.id])
                                Haptics.success()
                            }
                            .accessibilityElement()
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("trash.cell")
                    }
                }
            }
            .overlay {
                if store.trash.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash")
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                        .disabled(store.trash.isEmpty)
                        .accessibilityIdentifier("trash.empty")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .confirmationDialog("Delete \(store.trash.count) photos for good?", isPresented: $confirmEmpty,
                                titleVisibility: .visible) {
                Button("Delete for Good", role: .destructive) { store.emptyTrash() }
            } message: {
                Text("Their RAW files are removed from the app. Photos you exported stay in Photos.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
