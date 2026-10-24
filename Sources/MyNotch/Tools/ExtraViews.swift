import SwiftUI
import AppKit
import AVFoundation

// MARK: - Weather

struct WeatherView: View {
    private var w: WeatherService { .shared }
    private var unit: String { AppSettings.shared.temperatureUnit == .fahrenheit ? "°" : "°" }

    var body: some View {
        Group {
            if let now = w.now {
                HStack(spacing: 10) {
                    Card(padding: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(w.place ?? "Here").font(.system(size: 11.5, weight: .bold)).lineLimit(1)
                                Spacer()
                                IconButton(symbol: "arrow.clockwise", size: 9) { w.refresh() }
                            }
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: WeatherService.symbol(now.code, day: now.isDay))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 34))
                                Text("\(Int(now.temp.rounded()))\(unit)").font(.rounded(38, .semibold))
                            }
                            Text(WeatherService.describe(now.code)).font(.system(size: 11.5, weight: .medium))
                            Spacer(minLength: 0)
                            HStack(spacing: 10) {
                                Label("\(Int(now.feels.rounded()))\(unit)", systemImage: "thermometer.medium")
                                Label("\(Int(now.humidity))%", systemImage: "humidity.fill")
                                Label("\(Int(now.wind))", systemImage: "wind")
                            }
                            .font(.system(size: 9.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 210)
                    Card(padding: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Next hours")
                            HStack(spacing: 0) {
                                ForEach(w.hours.prefix(8)) { h in
                                    VStack(spacing: 5) {
                                        Text(h.date, format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                                        Image(systemName: WeatherService.symbol(h.code)).symbolRenderingMode(.multicolor).font(.system(size: 15)).frame(height: 18)
                                        Text("\(Int(h.temp.rounded()))°").font(.rounded(12, .semibold))
                                        Text(h.rain > 0 ? "\(h.rain)%" : " ").font(.system(size: 8.5)).foregroundStyle(.cyan)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Card(padding: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionLabel(text: "Week")
                            let lo = w.days.map(\.min).min() ?? 0, hi = w.days.map(\.max).max() ?? 1
                            ForEach(w.days.prefix(6)) { d in
                                HStack(spacing: 6) {
                                    Text(Calendar.current.isDateInToday(d.date) ? "Today" : d.date.formatted(.dateTime.weekday(.abbreviated)))
                                        .font(.system(size: 10)).frame(width: 34, alignment: .leading)
                                    Image(systemName: WeatherService.symbol(d.code)).symbolRenderingMode(.multicolor).font(.system(size: 10)).frame(width: 16)
                                    Text("\(Int(d.min.rounded()))°").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).frame(width: 24, alignment: .trailing)
                                    GeometryReader { g in
                                        let span = max(1, hi - lo)
                                        Capsule().fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(6, g.size.width * (d.max - d.min) / span), height: 4)
                                            .offset(x: g.size.width * (d.min - lo) / span, y: (g.size.height - 4) / 2)
                                    }
                                    .frame(height: 10)
                                    Text("\(Int(d.max.rounded()))°").font(.system(size: 9.5, weight: .semibold)).frame(width: 24, alignment: .leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: 210)
                }
            } else if w.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "cloud.sun", title: "Weather", subtitle: w.error ?? "Allow location or set a city in Settings.",
                           actionTitle: "Retry") { w.refresh() }
            }
        }
        .onAppear { w.refreshIfNeeded() }
    }
}

// MARK: - Search & links

struct LinksView: View {
    let vm: NotchViewModel
    @State private var query = ""
    @State private var engine = UserDefaults.standard.string(forKey: "searchEngine") ?? "Google"
    @FocusState private var focused: Bool
    private var settings: AppSettings { .shared }

    static let engines: [(name: String, symbol: String, url: String)] = [
        ("Google", "magnifyingglass", "https://www.google.com/search?q="),
        ("Claude", "asterisk", "https://claude.ai/new?q="),
        ("ChatGPT", "bubble.left.and.text.bubble.right", "https://chatgpt.com/?q="),
        ("Perplexity", "sparkle.magnifyingglass", "https://www.perplexity.ai/search?q="),
        ("DuckDuckGo", "shield.lefthalf.filled", "https://duckduckgo.com/?q="),
        ("YouTube", "play.rectangle.fill", "https://www.youtube.com/results?search_query="),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/search?type=repositories&q="),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: Self.engines.first { $0.name == engine }?.symbol ?? "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 18)
                TextField("Search \(engine)…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .onSubmit(search)
                PillButton(title: "Go", symbol: "arrow.up.right", prominent: true, action: search)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
            HStack(spacing: 5) {
                ForEach(Self.engines, id: \.name) { e in
                    Button {
                        engine = e.name
                        UserDefaults.standard.set(e.name, forKey: "searchEngine")
                    } label: {
                        Label(e.name, systemImage: e.symbol).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(engine == e.name ? .black : .white)
                            .background(Capsule().fill(engine == e.name ? Theme.accent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            SectionLabel(text: "Bookmarks", trailing: "Right-click to remove")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settings.bookmarks) { b in
                        Button {
                            if let u = b.url { NSWorkspace.shared.open(u); vm.close() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "globe").font(.system(size: 10))
                                Text(b.title).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Remove", role: .destructive) { settings.bookmarks.removeAll { $0.id == b.id } } }
                    }
                    Button(action: addBookmark) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    }
                    .buttonStyle(.plain).help("Bookmark the URL typed above")
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var url: URL?
        if q.range(of: #"^[\w-]+(\.[\w-]+)+(/\S*)?$"#, options: .regularExpression) != nil, !q.contains(" ") {
            url = URL(string: q.hasPrefix("http") ? q : "https://" + q)
        } else if let base = Self.engines.first(where: { $0.name == engine })?.url {
            url = URL(string: base + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q))
        }
        if let url { NSWorkspace.shared.open(url); query = ""; vm.close() }
    }

    private func addBookmark() {
        var s = query.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        if let u = URL(string: s) { settings.bookmarks.append(Pin.from(url: u)); query = "" }
    }
}

// MARK: - Unit converter

struct UnitsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case length = "Length", mass = "Weight", temperature = "Temp", volume = "Volume", speed = "Speed", data = "Data", time = "Time", currency = "Money"
        var id: String { rawValue }
    }
    @State private var category: Category = .length
    @State private var input = "1"
    @State private var from = 0
    @State private var to = 1
    private var rates: CurrencyRates { .shared }

    private var units: [(String, Dimension?)] {
        switch category {
        case .length: return [("m", UnitLength.meters), ("km", UnitLength.kilometers), ("cm", UnitLength.centimeters), ("mm", UnitLength.millimeters), ("mi", UnitLength.miles), ("ft", UnitLength.feet), ("in", UnitLength.inches), ("yd", UnitLength.yards)]
        case .mass: return [("kg", UnitMass.kilograms), ("g", UnitMass.grams), ("lb", UnitMass.pounds), ("oz", UnitMass.ounces), ("st", UnitMass.stones)]
        case .temperature: return [("°C", UnitTemperature.celsius), ("°F", UnitTemperature.fahrenheit), ("K", UnitTemperature.kelvin)]
        case .volume: return [("L", UnitVolume.liters), ("mL", UnitVolume.milliliters), ("gal", UnitVolume.gallons), ("cup", UnitVolume.cups), ("fl oz", UnitVolume.fluidOunces)]
        case .speed: return [("km/h", UnitSpeed.kilometersPerHour), ("mph", UnitSpeed.milesPerHour), ("m/s", UnitSpeed.metersPerSecond), ("kn", UnitSpeed.knots)]
        case .data: return [("MB", UnitInformationStorage.megabytes), ("GB", UnitInformationStorage.gigabytes), ("TB", UnitInformationStorage.terabytes), ("KB", UnitInformationStorage.kilobytes), ("Mb", UnitInformationStorage.megabits), ("MiB", UnitInformationStorage.mebibytes), ("GiB", UnitInformationStorage.gibibytes)]
        case .time: return [("min", UnitDuration.minutes), ("h", UnitDuration.hours), ("s", UnitDuration.seconds), ("ms", UnitDuration.milliseconds)]
        case .currency:
            let common = ["USD", "EUR", "INR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "SGD", "AED"]
            let list = common.filter { rates.rates[$0] != nil } + rates.rates.keys.filter { !common.contains($0) }.sorted()
            return (list.isEmpty ? common : list).map { ($0, nil) }
        }
    }

    private var result: String {
        let value = Double(input.replacingOccurrences(of: ",", with: ".")) ?? 0
        let u = units
        guard from < u.count, to < u.count else { return "—" }
        let out: Double
        if category == .currency {
            guard let a = rates.rates[u[from].0], let b = rates.rates[u[to].0], a > 0 else { return rates.rates.isEmpty ? "Loading rates…" : "—" }
            out = value / a * b
        } else {
            guard let fu = u[from].1, let tu = u[to].1 else { return "—" }
            out = Measurement(value: value, unit: fu).converted(to: tu).value
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(out) < 1 ? 6 : (abs(out) < 100 ? 4 : 2)
        return f.string(from: NSNumber(value: out)) ?? "\(out)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Category.allCases) { c in
                    Button { category = c; from = 0; to = 1; if c == .currency { rates.load() } } label: {
                        Text(c.rawValue).font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(category == c ? .black : .white)
                            .background(Capsule().fill(category == c ? Theme.accent : Color.white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Value", text: $input)
                        .textFieldStyle(.plain).font(.rounded(26, .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
                    unitPicker($from)
                }
                Button { swap(&from, &to) } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    Text(result).font(.rounded(26, .semibold)).foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.1)))
                        .textSelection(.enabled)
                    unitPicker($to)
                }
            }
            if category == .currency, let d = rates.updated {
                Text("Rates from frankfurter.dev · updated \(Fmt.ago(d))").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func unitPicker(_ sel: Binding<Int>) -> some View {
        Picker("", selection: sel) {
            ForEach(Array(units.enumerated()), id: \.offset) { i, u in Text(u.0).tag(i) }
        }
        .labelsHidden().controlSize(.small).frame(maxWidth: 160)
    }
}

// MARK: - Ambient sounds

struct SoundsView: View {
    private var engine: AmbientEngine { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Ambient sounds — layer as many as you like")
                if engine.playing { PillButton(title: "Stop all", symbol: "stop.fill") { engine.stopAll() } }
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Slider(value: Binding(get: { engine.master }, set: { engine.master = $0 }), in: 0...1).controlSize(.mini).frame(width: 90)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AmbientSound.allCases) { s in SoundTile(sound: s) }
            }
        }
    }
}

private struct SoundTile: View {
    var sound: AmbientSound
    private var engine: AmbientEngine { .shared }
    var body: some View {
        let v = engine.volumes[sound] ?? 0
        let on = v > 0.001
        HStack(spacing: 10) {
            Button { engine.toggle(sound) } label: {
                Image(systemName: sound.symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? .black : .white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(on ? Theme.accent : Color.white.opacity(0.1)))
                    .symbolEffect(.variableColor.iterative, isActive: on)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(sound.title).font(.system(size: 11.5, weight: .semibold))
                Slider(value: Binding(get: { v }, set: { engine.setVolume($0, for: sound) }), in: 0...1).controlSize(.mini)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent.opacity(0.1) : Theme.card))
    }
}

// MARK: - Camera mirror

struct CameraView: View {
    @State private var allowed: Bool?
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if allowed == true {
                    CameraPreview().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if allowed == false {
                    EmptyState(symbol: "video.slash", title: "Camera access is off",
                               subtitle: "Enable it in System Settings › Privacy & Security › Camera.",
                               actionTitle: "Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror").font(.system(size: 14, weight: .bold))
                Text("Check your hair before the call. The camera turns off the moment you leave this tab or close the notch — nothing is recorded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
        .onAppear { CameraService.shared.start { allowed = $0 } }
        .onDisappear { CameraService.shared.stop() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: CameraService.shared.session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let l = nsView.layer as? AVCaptureVideoPreviewLayer, let c = l.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }
}
