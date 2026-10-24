import AppKit
import SwiftUI
import Observation
import CoreLocation
import AVFoundation

// MARK: - Notes

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updated = Date()
    var title: String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Empty note" : String(first.prefix(40))
    }
}

@Observable
final class NotesStore {
    static let shared = NotesStore()
    var notes: [Note]
    var selectedID: UUID?
    /// Bumped to ask the Notes view to focus the quick-thought field.
    var focusToken = 0
    /// Characters typed while the Notes tab is showing but nothing is focused (type-to-write).
    var pendingTyping = ""
    @ObservationIgnored private let saver = Debouncer(0.6)

    init() {
        notes = Store.load([Note].self, from: "notes.json") ?? [Note(text: "Scratchpad\n\nThis is always here. Jot anything.")]
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } ?? notes.first }

    func update(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].updated = Date()
        save()
    }

    func add() {
        let n = Note(text: "")
        withAnimation { notes.insert(n, at: min(1, notes.count)) }
        selectedID = n.id
        save()
    }

    /// Saves a quick thought as its own note (newest first, right under the scratchpad).
    func addThought(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            notes.insert(Note(text: t), at: min(1, notes.count))
        }
        save()
    }

    func delete(_ note: Note) {
        guard notes.count > 1 else { update(note.id, text: ""); return }
        withAnimation { notes.removeAll { $0.id == note.id } }
        if selectedID == note.id { selectedID = notes.first?.id }
        save()
    }

    private func save() { saver.call { [notes] in Store.save(notes, to: "notes.json") } }
}

// MARK: - Weather (Open-Meteo, no account)

struct WeatherNow: Equatable { var temp: Double; var feels: Double; var humidity: Double; var wind: Double; var code: Int; var isDay: Bool }
struct WeatherHour: Equatable, Identifiable { var id: Date { date }; var date: Date; var temp: Double; var code: Int; var rain: Int }
struct WeatherDay: Equatable, Identifiable { var id: Date { date }; var date: Date; var min: Double; var max: Double; var code: Int; var rain: Int }

@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()
    var now: WeatherNow?
    var hours: [WeatherHour] = []
    var days: [WeatherDay] = []
    var place: String?
    var error: String?
    var loading = false
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var lastCoordinate: CLLocationCoordinate2D?

    func refreshIfNeeded() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 20 * 60, now != nil { return }
        refresh()
    }

    func refresh() {
        let s = AppSettings.shared
        loading = true
        error = nil
        if !s.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty && !s.weatherUseLocation {
            geocode(s.weatherCity)
        } else if s.weatherUseLocation {
            if manager == nil { manager = CLLocationManager(); manager?.delegate = self; manager?.desiredAccuracy = kCLLocationAccuracyKilometer }
            switch manager?.authorizationStatus {
            case .notDetermined: manager?.requestWhenInUseAuthorization()
            case .denied, .restricted:
                if !s.weatherCity.isEmpty { geocode(s.weatherCity) } else { fail("Location is off — set a city in Settings › Weather") }
            default: manager?.requestLocation()
            }
        } else {
            fail("Set a city in Settings › Weather")
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized: m.requestLocation()
        case .denied, .restricted:
            let city = AppSettings.shared.weatherCity
            if !city.isEmpty { geocode(city) } else if loading { fail("Location is off — set a city in Settings › Weather") }
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastCoordinate = loc.coordinate
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            DispatchQueue.main.async { self?.place = marks?.first?.locality ?? marks?.first?.name }
        }
        fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if let c = lastCoordinate { fetch(lat: c.latitude, lon: c.longitude); return }
        let city = AppSettings.shared.weatherCity
        if !city.isEmpty { geocode(city) } else { fail("Couldn't get your location") }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.loading = false; self.error = msg }
    }

    private func geocode(_ city: String) {
        let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
        guard let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=en&format=json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = (o["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
                self?.fail("Couldn't find “\(city)”"); return
            }
            DispatchQueue.main.async { self?.place = r["name"] as? String }
            self?.fetch(lat: lat, lon: lon)
        }.resume()
    }

    private func fetch(lat: Double, lon: Double) {
        let f = AppSettings.shared.temperatureUnit == .fahrenheit
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)" +
            "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day" +
            "&hourly=temperature_2m,weather_code,precipitation_probability" +
            "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
            "&timezone=auto&forecast_days=7" + (f ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : "")
        guard let url = URL(string: s) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self else { return }
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.fail(err?.localizedDescription ?? "Weather unavailable"); return
            }
            let offset = o["utc_offset_seconds"] as? Int ?? 0
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: offset)
            df.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let dd = DateFormatter()
            dd.locale = df.locale; dd.timeZone = df.timeZone; dd.dateFormat = "yyyy-MM-dd"

            var now: WeatherNow?
            if let c = o["current"] as? [String: Any] {
                now = WeatherNow(temp: c["temperature_2m"] as? Double ?? 0, feels: c["apparent_temperature"] as? Double ?? 0,
                                 humidity: c["relative_humidity_2m"] as? Double ?? 0, wind: c["wind_speed_10m"] as? Double ?? 0,
                                 code: c["weather_code"] as? Int ?? 0, isDay: (c["is_day"] as? Int ?? 1) == 1)
            }
            var hours: [WeatherHour] = []
            if let h = o["hourly"] as? [String: Any], let times = h["time"] as? [String] {
                let temps = h["temperature_2m"] as? [Double] ?? [], codes = h["weather_code"] as? [Int] ?? []
                let rain = h["precipitation_probability"] as? [Int?] ?? []
                for (i, t) in times.enumerated() {
                    guard let d = df.date(from: t), d > Date().addingTimeInterval(-3600) else { continue }
                    hours.append(WeatherHour(date: d, temp: i < temps.count ? temps[i] : 0, code: i < codes.count ? codes[i] : 0,
                                             rain: i < rain.count ? (rain[i] ?? 0) : 0))
                    if hours.count >= 12 { break }
                }
            }
            var days: [WeatherDay] = []
            if let d = o["daily"] as? [String: Any], let times = d["time"] as? [String] {
                let mx = d["temperature_2m_max"] as? [Double] ?? [], mn = d["temperature_2m_min"] as? [Double] ?? []
                let codes = d["weather_code"] as? [Int] ?? [], rain = d["precipitation_probability_max"] as? [Int?] ?? []
                for (i, t) in times.enumerated() {
                    guard let date = dd.date(from: t) else { continue }
                    days.append(WeatherDay(date: date, min: i < mn.count ? mn[i] : 0, max: i < mx.count ? mx[i] : 0,
                                           code: i < codes.count ? codes[i] : 0, rain: i < rain.count ? (rain[i] ?? 0) : 0))
                }
            }
            DispatchQueue.main.async {
                withAnimation {
                    self.now = now; self.hours = hours; self.days = days
                }
                self.loading = false
                self.error = nil
                self.lastFetch = Date()
            }
        }.resume()
    }

    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1: return day ? "sun.max.fill" : "moon.fill"
        case 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Storm with hail"
        default: return "—"
        }
    }
}

// MARK: - Camera mirror

final class CameraService {
    static let shared = CameraService()
    let session = AVCaptureSession()
    private var configured = false
    private let queue = DispatchQueue(label: "mynotch.camera")

    var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func start(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run(); completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.run() }; completion(ok) }
            }
        default: completion(false)
        }
    }

    private func run() {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
}

// MARK: - Currency rates (frankfurter.dev, cached for a day)

@Observable
final class CurrencyRates {
    static let shared = CurrencyRates()
    var rates: [String: Double] = [:]      // relative to USD
    var updated: Date?
    @ObservationIgnored private var loading = false

    struct Cache: Codable { var rates: [String: Double]; var date: Date }

    func load() {
        if let c = Store.load(Cache.self, from: "rates.json") { rates = c.rates; updated = c.date }
        guard !loading, (updated.map { Date().timeIntervalSince($0) > 12 * 3600 } ?? true) else { return }
        loading = true
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            defer { self.loading = false }
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var r = o["rates"] as? [String: Double] else { return }
            r["USD"] = 1
            DispatchQueue.main.async {
                self.rates = r
                self.updated = Date()
                Store.save(Cache(rates: r, date: Date()), to: "rates.json")
            }
        }.resume()
    }
}
