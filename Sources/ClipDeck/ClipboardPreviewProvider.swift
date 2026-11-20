import AppKit
import ClipDeckCore
import Foundation
import ImageIO

/// Values ready for presentation. Images are already downsampled; file entries
/// are saved paths only, never loaded file contents or Quick Look requests.
enum ClipboardPreviewContent {
    case loading
    case empty
    case text(String, truncated: Bool)
    case image(CGImage, detail: String)
    case files([String], truncated: Bool)
    case unsupported(String)
}

/// Generates a preview exclusively from a saved slot. It never reads the
/// system pasteboard, opens referenced files, renders HTML, or uses the network.
/// Work runs off the UI thread; completion is delivered on the main queue.
final class ClipboardPreviewProvider {
    private let queue = DispatchQueue(label: "app.clipdeck.preview", qos: .userInitiated)

    private static let textCharacterLimit = 20_000
    private static let textByteLimit = 256 * 1_024
    private static let richTextByteLimit = 1_024 * 1_024
    private static let itemLimit = 64
    private static let filePathCharacterLimit = 2_048

    func preview(
        _ payload: ClipboardPayload?,
        completion: @escaping (ClipboardPreviewContent) -> Void
    ) {
        queue.async {
            let content = autoreleasepool { Self.makePreview(payload) }
            DispatchQueue.main.async { completion(content) }
        }
    }

    private static func makePreview(_ payload: ClipboardPayload?) -> ClipboardPreviewContent {
        guard let payload, !payload.items.isEmpty else { return .empty }
        if let files = filePreview(payload) { return files }
        if let image = imagePreview(payload) { return image }
        if let text = textPreview(payload) { return text }

        var types: [String] = []
        var seen = Set<String>()
        for item in payload.items.prefix(itemLimit) {
            for representation in item.representations {
                guard seen.insert(representation.type).inserted else { continue }
                types.append(String(representation.type.prefix(100)))
                if types.count == 6 { break }
            }
            if types.count == 6 { break }
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(payload.byteCount), countStyle: .memory)
        let formats = types.isEmpty ? "Формат не указан" : types.joined(separator: "\n")
        return .unsupported("Предпросмотр этого формата недоступен.\n\n\(size) · элементов: \(payload.items.count)\n\n\(formats)")
    }

    private static func filePreview(_ payload: ClipboardPayload) -> ClipboardPreviewContent? {
        var paths: [String] = []
        var characters = 0
        var truncated = payload.items.count > itemLimit
        var skippedItems = false

        func append(_ path: String) {
            guard !path.isEmpty else { return }
            guard paths.count < itemLimit, characters < textCharacterLimit else {
                truncated = true
                return
            }
            let remaining = min(filePathCharacterLimit, textCharacterLimit - characters)
            let clipped = String(path.prefix(remaining))
            if clipped.count < path.count { truncated = true }
            characters += clipped.count
            paths.append(clipped)
        }

        for item in payload.items.prefix(itemLimit) {
            if let value = item.representations.first(where: { $0.type == "public.file-url" }),
               value.data.count <= 32 * 1_024,
               let raw = String(data: value.data, encoding: .utf8),
               let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.isFileURL {
                append(url.path)
            } else if let value = item.representations.first(where: { $0.type == "NSFilenamesPboardType" }),
                      value.data.count <= richTextByteLimit,
                      let propertyList = try? PropertyListSerialization.propertyList(
                        from: value.data, options: [], format: nil
                      ),
                      let savedPaths = propertyList as? [String] {
                if savedPaths.count > itemLimit { truncated = true }
                for path in savedPaths.prefix(itemLimit) { append(path) }
            } else {
                skippedItems = true
            }
        }
        guard !paths.isEmpty else { return nil }
        return .files(paths, truncated: truncated || skippedItems)
    }

    private static func imagePreview(_ payload: ClipboardPayload) -> ClipboardPreviewContent? {
        let preferredTypes = [
            "public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif",
            "com.compuserve.gif", "org.webmproject.webp", "public.webp", "com.microsoft.bmp"
        ]
        let rasterTypes = Set(preferredTypes)
        var attempts = 0
        for item in payload.items.prefix(itemLimit) {
            for type in preferredTypes {
                guard let representation = item.representations.first(where: { $0.type == type }) else { continue }
                attempts += 1
                // Alternate representations can rescue one unsupported image,
                // but a malformed multi-item payload must not monopolize work.
                guard attempts <= 4 else { return nil }
                guard let source = CGImageSourceCreateWithData(
                    representation.data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                ) else { continue }
                // Inspect the bytes' actual type as well as the declared
                // pasteboard type; never render SVG or document formats.
                guard let sourceType = CGImageSourceGetType(source),
                      rasterTypes.contains(sourceType as String) else { continue }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 900,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
                var detail = "Изображение"
                if let width, let height, width > 0, height > 0 { detail = "\(width) × \(height)" }
                if payload.items.count > 1 { detail += " · элементов: \(payload.items.count)" }
                if CGImageSourceGetCount(source) > 1 { detail += " · первый кадр" }
                return .image(thumbnail, detail: detail)
            }
        }
        return nil
    }

    private static func textPreview(_ payload: ClipboardPayload) -> ClipboardPreviewContent? {
        var chunks: [String] = []
        var characters = 0
        var truncated = payload.items.count > itemLimit
        var skippedItems = false

        for item in payload.items.prefix(itemLimit) {
            guard let decoded = decodeText(item) else {
                skippedItems = true
                continue
            }
            let separatorCount = chunks.isEmpty ? 0 : 2
            let remaining = textCharacterLimit - characters - separatorCount
            guard remaining > 0 else {
                truncated = true
                break
            }
            let clipped = String(decoded.value.prefix(remaining))
            truncated = truncated || decoded.truncated || clipped.count < decoded.value.count
            characters += separatorCount + clipped.count
            chunks.append(clipped)
        }
        guard !chunks.isEmpty else { return nil }
        // No whitespace trimming: line breaks, tabs and blank lines belong to
        // the user's copied content. Two line breaks separate distinct items.
        return .text(chunks.joined(separator: "\n\n"), truncated: truncated || skippedItems)
    }

    private static func decodeText(_ item: ClipboardPayload.Item) -> (value: String, truncated: Bool)? {
        let preferredTypes = [
            "public.utf8-plain-text", "public.utf16-external-plain-text",
            "public.utf16-plain-text", "public.plain-text", "public.text", "NSStringPboardType"
        ]
        for type in preferredTypes {
            guard let value = item.representations.first(where: { $0.type == type }) else { continue }
            let truncated = value.data.count > textByteLimit
            let prefix = Data(value.data.prefix(textByteLimit))
            let leading = Array(prefix.prefix(2))
            let hasUTF16BOM = leading == [0xFF, 0xFE] || leading == [0xFE, 0xFF]
            if type.contains("utf16") || hasUTF16BOM {
                let bytes = Array(prefix)
                let bigEndian = leading == [0xFE, 0xFF]
                let start = hasUTF16BOM ? 2 : 0
                var units: [UInt16] = []
                units.reserveCapacity(max(0, bytes.count - start) / 2)
                var index = start
                while index + 1 < bytes.count {
                    let first = UInt16(bytes[index])
                    let second = UInt16(bytes[index + 1])
                    units.append(bigEndian ? (first << 8) | second : first | (second << 8))
                    index += 2
                }
                return (String(decoding: units, as: UTF16.self), truncated || index < bytes.count)
            }
            // String(decoding:) tolerates a partial final UTF-8 scalar after
            // the explicit byte cap. The UI marks that preview as truncated.
            var text = String(decoding: prefix, as: UTF8.self)
            if text.first == "\u{FEFF}" { text.removeFirst() }
            return (text, truncated)
        }

        if let value = item.representations.first(where: {
            $0.type == "public.rtf" || $0.type == "NSRTFPboardType"
        }), value.data.count <= richTextByteLimit,
           let attributed = try? NSAttributedString(
            data: value.data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            // RTF is materialized from the stored bytes; HTML/RTFD imports are
            // intentionally excluded so no referenced resource is fetched.
            return (attributed.string, false)
        }
        return nil
    }
}
