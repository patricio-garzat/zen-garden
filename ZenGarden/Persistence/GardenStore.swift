import Foundation
import UIKit

/// Local storage for gardens, in Application Support (kept across Xcode reinstalls as long as
/// the app is not deleted from the iPhone).
///
///   ZenGarden/current/garden.json + heights.bin        the garden in progress
///   ZenGarden/gallery/<id>/garden.json + heights.bin + thumb.jpg
///
/// Heights are half floats compressed with LZFSE (a full garden is ~0.3–1 MB).
final class GardenStore {
    static let shared = GardenStore()

    struct Entry: Identifiable {
        let id: UUID
        let doc: GardenDocument
        let thumbnail: URL?
    }

    private let fm = FileManager.default
    private let io = DispatchQueue(label: "zen.store", qos: .utility)
    let root: URL

    private init() {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("ZenGarden", isDirectory: true)
        try? fm.createDirectory(at: currentDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: galleryDir, withIntermediateDirectories: true)
    }

    private var currentDir: URL { root.appendingPathComponent("current", isDirectory: true) }
    private var galleryDir: URL { root.appendingPathComponent("gallery", isDirectory: true) }

    // MARK: - Current garden

    func saveCurrent(_ doc: GardenDocument, heights: Data, synchronous: Bool = false) {
        let dir = currentDir
        let work: () -> Void = { [weak self] in _ = self?.write(doc, heights: heights, thumbnail: nil, to: dir) }
        if synchronous { io.sync { work() } } else { io.async { work() } }
    }

    func loadCurrent() -> (GardenDocument, Data)? { read(currentDir) }

    // MARK: - Gallery

    func saveToGallery(_ doc: GardenDocument, heights: Data, thumbnail: CGImage?) {
        guard let id = doc.galleryID else { return }
        let dir = galleryDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let jpeg = thumbnail.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.85) }
        io.async { [weak self] in self?.write(doc, heights: heights, thumbnail: jpeg, to: dir) }
    }

    func galleryCount() -> Int {
        (try? fm.contentsOfDirectory(atPath: galleryDir.path).count) ?? 0
    }

    func listGallery() -> [Entry] {
        io.sync {}   // let pending writes finish
        guard let dirs = try? fm.contentsOfDirectory(at: galleryDir, includingPropertiesForKeys: nil) else { return [] }
        let entries: [Entry] = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("garden.json")),
                  let doc = try? JSONDecoder.zen.decode(GardenDocument.self, from: data),
                  let id = doc.galleryID else { return nil }
            let thumb = dir.appendingPathComponent("thumb.jpg")
            return Entry(id: id, doc: doc, thumbnail: fm.fileExists(atPath: thumb.path) ? thumb : nil)
        }
        return entries.sorted { $0.doc.modified > $1.doc.modified }
    }

    func loadGallery(_ id: UUID) -> (GardenDocument, Data)? {
        io.sync {}
        return read(galleryDir.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func deleteGallery(_ id: UUID) {
        io.sync { try? fm.removeItem(at: galleryDir.appendingPathComponent(id.uuidString, isDirectory: true)) }
    }

    func deleteAll() {
        io.sync {
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: currentDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: galleryDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Files

    private func write(_ doc: GardenDocument, heights: Data, thumbnail: Data?, to dir: URL) {
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let json = try JSONEncoder.zen.encode(doc)
            let packed = (try? (heights as NSData).compressed(using: .lzfse) as Data) ?? heights
            try packed.write(to: dir.appendingPathComponent("heights.bin"), options: .atomic)
            try json.write(to: dir.appendingPathComponent("garden.json"), options: .atomic)
            if let thumbnail { try thumbnail.write(to: dir.appendingPathComponent("thumb.jpg"), options: .atomic) }
        } catch {
            #if DEBUG
            print("Zen Garden: could not save garden: \(error)")
            #endif
        }
    }

    private func read(_ dir: URL) -> (GardenDocument, Data)? {
        guard let json = try? Data(contentsOf: dir.appendingPathComponent("garden.json")),
              let doc = try? JSONDecoder.zen.decode(GardenDocument.self, from: json),
              let packed = try? Data(contentsOf: dir.appendingPathComponent("heights.bin")) else { return nil }
        let heights = (try? (packed as NSData).decompressed(using: .lzfse) as Data) ?? packed
        guard doc.heightWidth > 0, heights.count >= doc.heightWidth * doc.heightHeight * 2 else { return nil }
        return (doc, heights)
    }
}

extension JSONEncoder {
    static let zen: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let zen: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
