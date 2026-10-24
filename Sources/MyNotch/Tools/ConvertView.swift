import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConvertView: View {
    private var c: ConverterStore { .shared }
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            inputPane
            optionsPane.frame(width: 250)
        }
    }

    // MARK: Inputs

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionLabel(text: c.inputs.isEmpty ? "Files" : "\(c.inputs.count) file\(c.inputs.count == 1 ? "" : "s")")
                if !ShelfStore.shared.items.isEmpty {
                    PillButton(title: "From Shelf", symbol: "tray.full") { c.add(ShelfStore.shared.items.map(\.url)) }
                }
                PillButton(title: "Choose…", symbol: "plus") { c.choose() }
                if !c.inputs.isEmpty { IconButton(symbol: "trash", size: 10, help: "Clear") { c.clear() } }
            }
            Group {
                if let r = c.result {
                    resultView(r)
                } else if c.inputs.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard").font(.system(size: 24)).foregroundStyle(Theme.tertiary)
                            .symbolEffect(.bounce, value: targeted)
                        Text("Drop any image, PDF or document here").font(.system(size: 12.5, weight: .semibold))
                        Text("Images (WebP, HEIC, PNG, JPG…) · PDF · DOCX · CSV · TXT · MD · RTF · HTML").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(c.inputs.enumerated()), id: \.element) { i, u in
                                InputTile(url: u) {
                                    PreviewCenter.shared.show(c.inputs.map { PreviewItem(title: $0.lastPathComponent, kind: ConverterStore.isPDF($0) ? .file($0) : .image($0)) }, at: i)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { c.accept($0) }
        }
    }

    private func resultView(_ r: ConvertResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: r.outputs.isEmpty ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(r.outputs.isEmpty ? .red : .green)
                Text(r.outputs.isEmpty ? "Nothing could be converted" : "\(r.outputs.count) file\(r.outputs.count == 1 ? "" : "s") in “\(ConverterStore.outputFolderName)”")
                    .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                if r.bytesIn > 0, !r.outputs.isEmpty {
                    Text("\(Fmt.bytes(r.bytesIn)) → \(Fmt.bytes(r.bytesOut))").font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            if !r.failures.isEmpty {
                Text("Couldn't read: " + r.failures.joined(separator: ", ")).font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(r.outputs.enumerated()), id: \.element) { i, u in
                        InputTile(url: u) {
                            PreviewCenter.shared.show(r.outputs.map { PreviewItem(title: $0.lastPathComponent, kind: ConverterStore.isPDF($0) ? .file($0) : .image($0)) }, at: i)
                        }
                        .onDrag { fileDragProvider(u) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                if !r.outputs.isEmpty {
                    PillButton(title: "Open Folder", symbol: "folder.fill", prominent: true) {
                        NSWorkspace.shared.open(r.outputs[0].deletingLastPathComponent())
                    }
                    PillButton(title: "Add to Shelf", symbol: "tray.and.arrow.down") { ShelfStore.shared.add(urls: r.outputs) }
                }
                Spacer()
                PillButton(title: "Convert more", symbol: "arrow.counterclockwise") { c.clear() }
            }
        }
        .padding(10)
    }

    // MARK: Options

    private var hasPDFInput: Bool { c.inputs.contains(where: ConverterStore.isPDF) }

    private var optionsPane: some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Convert to").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.secondary)
                HStack(spacing: 4) {
                    ForEach(ConvertFormat.allCases) { f in
                        Button { c.format = f } label: {
                            Text(f.title).font(.system(size: 10.5, weight: .bold))
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .foregroundStyle(c.format == f ? .black : .white)
                                .background(RoundedRectangle(cornerRadius: 7).fill(c.format == f ? Theme.accent : Color.white.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
                if c.format == .pdf {
                    Toggle(c.inputs.allSatisfy(ConverterStore.isPDF) ? "Merge into one PDF" : "Combine into one PDF", isOn: Binding(get: { c.combinePDF }, set: { c.combinePDF = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
                } else if hasPDFInput || c.inputs.contains(where: ConverterStore.isDocument) {
                    Text("Each page becomes its own image").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                }
                if c.format.lossy || c.format == .pdf {
                    HStack(spacing: 6) {
                        Text("Quality").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                        Slider(value: Binding(get: { c.quality }, set: { c.quality = $0 }), in: 0.3...1).controlSize(.mini)
                        Text("\(Int(c.quality * 100))%").font(.system(size: 10, design: .rounded)).frame(width: 30)
                    }
                }
                HStack(spacing: 6) {
                    Text("Size").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { c.maxSide }, set: { c.maxSide = $0 })) {
                        Text("Original").tag(0); Text("4096 px").tag(4096); Text("2048 px").tag(2048)
                        Text("1080 px").tag(1080); Text("512 px").tag(512)
                    }.labelsHidden().controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Text("Save to").font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                    Picker("", selection: Binding(get: { c.destination }, set: { c.destination = $0 })) {
                        ForEach(ConvertDestination.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().controlSize(.mini)
                }
                Spacer(minLength: 0)
                Button(action: c.convert) {
                    HStack(spacing: 6) {
                        if c.working { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text(c.working ? "Converting \(Int(c.progress * 100))%" : "Convert \(c.inputs.isEmpty ? "" : "\(c.inputs.count) ")to \(c.format.title)")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .foregroundStyle(.black)
                    .background(RoundedRectangle(cornerRadius: 10).fill(c.inputs.isEmpty ? Color.white.opacity(0.25) : Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(c.inputs.isEmpty || c.working)
            }
        }
    }
}

private struct InputTile: View {
    var url: URL
    var onPreview: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) }
                    else { FileIcon(path: url.path, size: 72) }
                }
                .frame(width: 112, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(hover ? 0.3 : 0.08)))
                .overlay(alignment: .bottomTrailing) {
                    if hover {
                        Image(systemName: "eye.fill").font(.system(size: 9.5, weight: .bold))
                            .frame(width: 22, height: 22).background(Circle().fill(Color.black.opacity(0.65))).padding(5)
                    }
                }
                if hover {
                    Button { ConverterStore.shared.remove(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, Color(white: 0.25))
                    }.buttonStyle(.plain).offset(x: 5, y: -5)
                }
            }
            Text(url.lastPathComponent).font(.system(size: 9.5)).lineLimit(1).frame(width: 112).foregroundStyle(Theme.secondary)
            Text(url.pathExtension.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onPreview)
        .help("Click to preview")
        .onAppear {
            ShelfStore.shared.thumbnail(for: ShelfItem(path: url.path), size: 240) { thumb = $0 }
        }
    }
}
