import SwiftUI

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [GardenStore.Entry] = []
    @State private var pendingDelete: GardenStore.Entry?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: T("My gardens", "Mis jardines")) { dismiss() }
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.grid.2x2").font(.system(size: 34, weight: .ultraLight))
                    Text(T("No saved gardens yet", "Aún no hay jardines guardados")).font(.system(size: 17, weight: .medium))
                    Text(T("In the garden, open the menu and choose Save garden.",
                           "En el jardín, abre el menú y elige Guardar jardín."))
                        .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(32)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(entries) { e in card(e) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
        }
        .onAppear { entries = GardenStore.shared.listGallery() }
        .confirmationDialog(T("Delete this garden?", "¿Borrar este jardín?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(T("Delete", "Borrar"), role: .destructive) {
                if let e = pendingDelete {
                    GardenStore.shared.deleteGallery(e.id)
                    withAnimation(.easeInOut(duration: 0.3)) { entries.removeAll { $0.id == e.id } }
                }
                pendingDelete = nil
            }
            Button(T("Cancel", "Cancelar"), role: .cancel) { pendingDelete = nil }
        }
        .presentationDragIndicator(.visible)
    }

    private func card(_ e: GardenStore.Entry) -> some View {
        Button {
            Feedback.tap()
            model.openGallery(e.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZenPalette.sand.opacity(0.5))
                    if let url = e.thumbnail, let img = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                }
                .aspectRatio(0.62, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.doc.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(e.doc.modified, style: .date).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Feedback.tap()
                        pendingDelete = e
                    } label: {
                        Image(systemName: "trash").font(.system(size: 14)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(SoftPressStyle())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(T("Delete", "Borrar"))
                }
            }
        }
        .buttonStyle(SoftPressStyle())
        .foregroundStyle(.primary)
    }
}
