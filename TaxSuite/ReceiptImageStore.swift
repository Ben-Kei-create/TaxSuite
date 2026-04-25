import Foundation

enum ReceiptImageStore {
    nonisolated private static let directoryName = "ReceiptImages"

    nonisolated static func saveJPEGData(_ data: Data, capturedAt: Date = Date(), pageIndex: Int) throws -> String {
        let fileName = makeFileName(capturedAt: capturedAt, pageIndex: pageIndex)
        let fileURL = try directoryURL().appendingPathComponent(fileName)
        try data.write(to: fileURL, options: [.atomic])
        return fileName
    }

    nonisolated static func url(forFileName fileName: String?) -> URL? {
        guard let fileName,
              !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let directory = try? directoryURL() else {
            return nil
        }

        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func delete(fileName: String?) {
        guard let url = url(forFileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func delete(fileNames: [String?]) {
        fileNames.forEach { delete(fileName: $0) }
    }

    nonisolated private static func directoryURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        return directoryURL
    }

    nonisolated private static func makeFileName(capturedAt: Date, pageIndex: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"

        let timestamp = formatter.string(from: capturedAt)
        let page = String(format: "%02d", pageIndex + 1)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "receipt_\(timestamp)_p\(page)_\(suffix).jpg"
    }
}
