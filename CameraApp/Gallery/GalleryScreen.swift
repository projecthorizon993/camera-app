import SwiftUI
import UIKit
import os

// Task 15 — gallery screen.

struct GalleryScreen: View {
    let model: GalleryViewModel
    @State private var viewerItem: GalleryItem?
    @State private var sharePresented: Bool = false
    @State private var shareURL: URL?
    @State private var showPhotosAlert = false

    var body: some View {
        Group {
            switch model.status {
            case .loading:
                loadingView
            case .empty:
                emptyView
            case .denied:
                deniedView
            case .loaded:
                gridView
            }
        }
        .navigationTitle("Gallery")
        .toolbar { toolbarContent }
        .task {
            await model.load()
        }
        .sheet(item: $viewerItem) { item in
            GalleryViewer(item: item, model: model)
        }
        .sheet(isPresented: $sharePresented) {
            if let url = shareURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .padding()
            }
        }
        .confirmationDialog("Open in Photos", isPresented: $showPhotosAlert) {
            Button("Open Stock Photos App") {
                openStockPhotos()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open the system Photos app to view your full camera roll.")
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
            Text("Loading…")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No captures yet")
                .font(Theme.Typography.title)
            Text("Photos and videos you capture will appear here.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var deniedView: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Photo Access Needed")
                .font(Theme.Typography.title)
            Text("Allow photo library access to view your captures.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Allow Photo Access") {
                Task { await model.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: Theme.Spacing.s
            ) {
                ForEach(model.items) { item in
                    GalleryCell(
                        item: item,
                        thumbnail: model.thumbnails[item.id],
                        isSelected: model.selected.contains(item.id),
                        selectionMode: model.selectionMode
                    )
                    .onTapGesture { handleTap(item) }
                    .task { await model.ensureThumbnail(for: item) }
                }
            }
            .padding(Theme.Spacing.s)
        }
    }

    // MARK: - Actions

    private func handleTap(_ item: GalleryItem) {
        if model.selectionMode {
            model.toggleSelection(item.id)
        } else {
            viewerItem = item
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(model.selectionMode ? "Done" : "Select") {
                model.setSelectionMode(!model.selectionMode)
            }
        }
        if model.selectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", role: .destructive) {
                    Task { await model.deleteSelected() }
                }
                .disabled(model.selected.isEmpty)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showPhotosAlert = true
            } label: {
                Image(systemName: "photo.on.rectangle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    guard let id = (model.selected.isEmpty ? model.items.first?.id : model.selected.first),
                          let item = model.items.first(where: { $0.id == id }) else { return }
                    shareURL = await model.shareURL(for: item)
                    if shareURL != nil { sharePresented = true }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Actions

    private func openStockPhotos() {
        let photosURL = URL(string: "photos-redirect://")!
        if UIApplication.shared.canOpenURL(photosURL) {
            UIApplication.shared.open(photosURL)
        } else {
            let alt = URL(string: "com.apple.mobileslideshow://")!
            UIApplication.shared.open(alt)
        }
        Logger.ui("opened stock Photos app from gallery")
    }

}
