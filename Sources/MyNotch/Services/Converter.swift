import AppKit
import SwiftUI
import Observation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// File converter: images ⇄ JPG/PNG/HEIC/TIFF, images → PDF, PDF → images, merge PDFs.
/// Everything happens on-device with ImageIO and PDFKit.
enum ConvertFormat: String, CaseIterable, Identifiable {
    case jpg, png, heic, tiff, pdf
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }
    var utType: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        }
    }
    var lossy: Bool { self == .jpg || self == .heic }
}

enum ConvertDestination: String, CaseIterable, Identifiable {
    case nextToOriginal, downloads, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nextToOriginal: "Next to originals"
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        }
    }
}

struct ConvertResult: Equatable {
    var outputs: [URL]
    var failures: [String]
    var bytesIn: Int64
    var bytesOut: Int64
}

@Observable
final class ConverterStore {
    static let shared = ConverterStore()

    var inputs: [URL] = []
    var format: ConvertFormat = ConvertFormat(rawValue: UserDefaults.standard.string(forKey: "convertFormat") ?? "") ?? .jpg {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "convertFormat") }
    }
    var quality: Double = UserDefaults.standard.object(forKey: "convertQuality") as? Double ?? 0.85 {
        didSet { UserDefaults.standard.set(quality, forKey: "convertQuality") }
    }
    var maxSide: Int = UserDefaults.standard.integer(forKey: "convertMaxSide") {    // 0 = original size
        didSet { UserDefaults.standard.set(maxSide, forKey: "convertMaxSide") }
    }
    var combinePDF = true
    var destination: ConvertDestination = ConvertDestination(rawValue: UserDefaults.standard.string(forKey: "convertDest") ?? "") ?? .downloads {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "convertDest") }
    }
    var working = false
    var progress = 0.0
    var result: ConvertResult?

    static let readableTypes: [UTType] = [.image, .pdf, .text, .rtf, .html, .commaSeparatedText,
                                          UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "doc") ?? .data,
                                          UTType(filenameExtension: "odt") ?? .data, UTType(filenameExtension: "md") ?? .text]
    static let documentExts: Set<String> = ["docx", "doc", "odt", "rtf", "rtfd", "txt", "text", "md", "markdown", "csv", "tsv",
                                            "html", "htm", "json", "xml", "log", "yaml", "yml", "swift", "py", "js", "ts", "tsx", "jsx",
                                            "java", "c", "cpp", "h", "go", "rs", "rb", "sh", "css", "sql"]
    static func isDocument(_ url: URL) -> Bool { documentExts.contains(url.pathExtension.lowercased()) }

    func add(_ urls: [URL]) {
        let ok = urls.filter { Self.isSupported($0) && !inputs.contains($0) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { inputs.append(contentsOf: ok) }
        result = nil
    }

    func remove(_ url: URL) { withAnimation { inputs.removeAll { $0 == url } } }
    func clear() { withAnimation { inputs.removeAll(); result = nil } }

    static func isSupported(_ url: URL) -> Bool {
        if isDocument(url) { return true }
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .pdf)
    }

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
    static let outputFolderName = "MyNotch Converted"

    /// Folder the current destination writes to (for "Open Folder").
    var outputFolder: URL {
        let base: URL
        switch destination {
        case .desktop: base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .nextToOriginal: base = result?.outputs.first?.deletingLastPathComponent().deletingLastPathComponent()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .downloads: base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        return base.appendingPathComponent(Self.outputFolderName, isDirectory: true)
    }

    // MARK: Documents → PDF (DOCX, DOC, ODT, RTF, HTML, TXT, Markdown, CSV, code…)

    /// Renders a document to a paginated PDF. Uses AppKit text layout, so it runs on the main thread.
    static func documentPDF(_ url: URL) -> PDFDocument? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { documentPDF(url) } }
        let ext = url.pathExtension.lowercased()
        var landscape = false
        let attr: NSAttributedString?
        switch ext {
        case "csv", "tsv":
            guard let text = try? String(contentsOf: url, encoding: .utf8) ?? String(contentsOf: url, encoding: .isoLatin1) else { return nil }
            let rows = parseCSV(text, separator: ext == "tsv" ? "\t" : ",")
            landscape = (rows.map(\.count).max() ?? 0) > 6
            attr = htmlAttributed(csvHTML(rows, title: url.deletingPathExtension().lastPathComponent))
        case "md", "markdown":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            if let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                let m = NSMutableAttributedString(a)
                m.addAttribute(.font, value: NSFont.systemFont(ofSize: 11.5), range: NSRange(location: 0, length: m.length))
                attr = m
            } else { attr = plain(text) }
        case "docx", "doc", "odt", "rtf", "rtfd", "html", "htm":
            attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
        default:
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
            attr = plain(text, mono: !["txt", "text", "log"].contains(ext))
        }
        guard let attr, attr.length > 0 else { return nil }
        return paginate(attr, landscape: landscape)
    }

    private static func plain(_ text: String, mono: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular) : NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.black,
        ])
    }

    private static func htmlAttributed(_ html: String) -> NSAttributedString? {
        NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    }

    static func parseCSV(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = text.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "\"" { quoted = false } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == separator { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func csvHTML(_ rows: [[String]], title: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        var h = "<html><head><style>body{font-family:-apple-system,Helvetica;font-size:9pt;color:#111}"
        h += "table{border-collapse:collapse;width:100%}td,th{border:1px solid #bbb;padding:3px 5px;text-align:left}"
        h += "th{background:#eee;font-weight:bold}h3{font-size:12pt}</style></head><body><h3>\(esc(title))</h3><table>"
        for (i, r) in rows.enumerated() {
            h += "<tr>" + r.map { i == 0 ? "<th>\(esc($0))</th>" : "<td>\(esc($0))</td>" }.joined() + "</tr>"
        }
        return h + "</table></body></html>"
    }

    private static func paginate(_ attr: NSAttributedString, landscape: Bool) -> PDFDocument? {
        let info = NSPrintInfo()
        info.paperSize = landscape ? NSSize(width: 842, height: 595) : NSSize(width: 595, height: 842)   // A4
        info.orientation = landscape ? .landscape : .portrait
        for m in [\NSPrintInfo.topMargin, \NSPrintInfo.bottomMargin, \NSPrintInfo.leftMargin, \NSPrintInfo.rightMargin] { info[keyPath: m] = 48 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mynotch-\(UUID().uuidString).pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp

        let width = info.paperSize.width - 96
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.backgroundColor = .white
        tv.drawsBackground = true
        tv.textContainerInset = .zero
        tv.textStorage?.setAttributedString(attr)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.sizeToFit()
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height
            tv.setFrameSize(NSSize(width: width, height: max(h, 20)))
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let data = try? Data(contentsOf: tmp) else { return nil }
        return PDFDocument(data: data)
    }

    func accept(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { self.add([url]) } }
            }
        }
        return handled
    }

    func choose() {
        NotchManager.shared?.presentDialog(reopen: .convert) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = Self.readableTypes
            panel.prompt = "Add"
            if panel.runModal() == .OK { self.add(panel.urls) }
        }
    }

    // MARK: Run

    func convert() {
        guard !inputs.isEmpty, !working else { return }
        working = true
        progress = 0
        result = nil
        let job = Job(inputs: inputs, format: format, quality: quality, maxSide: maxSide,
                      combinePDF: combinePDF, destination: destination)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = job.run { p in DispatchQueue.main.async { self.progress = p } }
            DispatchQueue.main.async {
                self.working = false
                withAnimation { self.result = r }
                if !r.outputs.isEmpty {
                    PeekCenter.shared.post(Peek(symbol: "checkmark.circle.fill", tint: .green,
                                                title: "Converted \(r.outputs.count) file\(r.outputs.count == 1 ? "" : "s")",
                                                subtitle: r.outputs.first?.lastPathComponent, tool: .convert, duration: 3,
                                                style: .success, sound: NSSound.Name("Pop")))
                }
            }
        }
    }

    private struct Job {
        var inputs: [URL]
        var format: ConvertFormat
        var quality: Double
        var maxSide: Int
        var combinePDF: Bool
        var destination: ConvertDestination

        func run(progress: (Double) -> Void) -> ConvertResult {
            var outputs: [URL] = []
            var failures: [String] = []
            let bytesIn = inputs.reduce(Int64(0)) { $0 + Self.size($1) }

            if format == .pdf {
                if combinePDF && inputs.count > 1 {
                    let doc = PDFDocument()
                    for (i, url) in inputs.enumerated() {
                        if !appendPages(of: url, to: doc) { failures.append(url.lastPathComponent) }
                        progress(Double(i + 1) / Double(inputs.count))
                    }
                    let name = (Self.isAllPDF(inputs) ? "Merged" : "Combined") + " \(Self.stamp())"
                    let out = Self.unique(folder(for: inputs[0]).appendingPathComponent(name).appendingPathExtension("pdf"))
                    if doc.pageCount > 0, doc.write(to: out) { outputs.append(out) }
                } else {
                    for (i, url) in inputs.enumerated() {
                        let doc = PDFDocument()
                        let out = Self.unique(folder(for: url).appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf"))
                        if appendPages(of: url, to: doc), doc.write(to: out) { outputs.append(out) } else { failures.append(url.lastPathComponent) }
                        progress(Double(i + 1) / Double(inputs.count))
                    }
                }
            } else {
                for (i, url) in inputs.enumerated() {
                    let base = url.deletingPathExtension().lastPathComponent
                    let dir = folder(for: url)
                    if ConverterStore.isPDF(url) || ConverterStore.isDocument(url) {
                        guard let doc = ConverterStore.isPDF(url) ? PDFDocument(url: url) : ConverterStore.documentPDF(url),
                              doc.pageCount > 0 else { failures.append(url.lastPathComponent); continue }
                        for p in 0..<doc.pageCount {
                            guard let page = doc.page(at: p), let img = render(page) else { continue }
                            let suffix = doc.pageCount > 1 ? " – page \(p + 1)" : ""
                            let out = Self.unique(dir.appendingPathComponent(base + suffix).appendingPathExtension(format.ext))
                            if write(img, to: out) { outputs.append(out) }
                        }
                    } else {
                        guard let img = loadImage(url) else { failures.append(url.lastPathComponent); continue }
                        let out = Self.unique(dir.appendingPathComponent(base).appendingPathExtension(format.ext))
                        if write(img, to: out) { outputs.append(out) } else { failures.append(url.lastPathComponent) }
                    }
                    progress(Double(i + 1) / Double(inputs.count))
                }
            }
            let bytesOut = outputs.reduce(Int64(0)) { $0 + Self.size($1) }
            return ConvertResult(outputs: outputs, failures: failures, bytesIn: bytesIn, bytesOut: bytesOut)
        }

        /// Every conversion lands in one "MyNotch Converted" folder so results are easy to find.
        private func folder(for url: URL) -> URL {
            let base: URL
            switch destination {
            case .downloads: base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            case .desktop: base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            case .nextToOriginal:
                let dir = url.deletingLastPathComponent()
                base = FileManager.default.isWritableFile(atPath: dir.path) && !dir.path.hasPrefix(Paths.appSupport.path)
                    && !dir.path.hasPrefix(Paths.home.appendingPathComponent("Library").path)
                    ? dir : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            }
            let out = base.appendingPathComponent(ConverterStore.outputFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            return out
        }

        /// Loads an image honoring EXIF orientation, downscaled to `maxSide` if set.
        private func loadImage(_ url: URL) -> CGImage? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var longest = maxSide
            if longest <= 0, let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                longest = max(w, h)
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, longest),
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }

        /// Renders a PDF page on white at ~200 dpi (or fitted to maxSide).
        private func render(_ page: PDFPage) -> CGImage? {
            let box = page.bounds(for: .mediaBox)
            var scale: CGFloat = 200.0 / 72.0
            if maxSide > 0 { scale = CGFloat(maxSide) / max(box.width, box.height) }
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage()
        }

        private func write(_ image: CGImage, to url: URL) -> Bool {
            var img = image
            // JPEG has no alpha: flatten transparent images onto white instead of black.
            if format == .jpg, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
               let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                if let flat = ctx.makeImage() { img = flat }
            }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else { return false }
            var props: [CFString: Any] = [:]
            if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }

        private func appendPages(of url: URL, to doc: PDFDocument) -> Bool {
            if ConverterStore.isPDF(url) || ConverterStore.isDocument(url) {
                guard let src = ConverterStore.isPDF(url) ? PDFDocument(url: url) : ConverterStore.documentPDF(url) else { return false }
                for i in 0..<src.pageCount { if let p = src.page(at: i) { doc.insert(p, at: doc.pageCount) } }
                return src.pageCount > 0
            }
            guard let cg = loadImage(url) else { return false }
            // Keep JPEG-sized output: re-encode with the chosen quality before placing on the page.
            let rep = NSBitmapImageRep(cgImage: cg)
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) ?? rep.representation(using: .png, properties: [:])
            guard let data, let ns = NSImage(data: data) else { return false }
            ns.size = NSSize(width: cg.width, height: cg.height)   // 1 px = 1 pt keeps aspect; viewers fit to width
            guard let page = PDFPage(image: ns) else { return false }
            doc.insert(page, at: doc.pageCount)
            return true
        }

        static func isAllPDF(_ urls: [URL]) -> Bool { urls.allSatisfy(ConverterStore.isPDF) }

        static func size(_ url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        static func unique(_ url: URL) -> URL {
            var u = url
            var n = 2
            let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
            while FileManager.default.fileExists(atPath: u.path) {
                u = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
                n += 1
            }
            return u
        }

        static func stamp() -> String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"; return f.string(from: Date())
        }
    }
}
