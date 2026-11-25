import SwiftUI
import CoreLocation
import FieldCore

/// Explicit foreground work sharing is independent from offline route recording.
@MainActor final class WebsiteWorkLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var active = false
    @Published private(set) var message = "Рабочее положение не передаётся"
    private let manager = CLLocationManager()
    private weak var account: WebsiteAccount?
    private var sending = false
    private var lastSent = Date.distantPast
    private var token: String?
    private var generation = UUID()
    private let deviceID: String = {
        let key = "website-work-device"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString; UserDefaults.standard.set(value, forKey: key); return value
    }()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest; manager.distanceFilter = kCLDistanceFilterNone }
    private func sequence() -> Int {
        let value = UserDefaults.standard.integer(forKey: "website-work-sequence") + 1
        UserDefaults.standard.set(value, forKey: "website-work-sequence"); return value
    }
    func start(_ account: WebsiteAccount) {
        do { token = try account.accountToken() } catch { message = error.localizedDescription; return }
        self.account = account; generation = UUID(); active = true; lastSent = .distantPast
        message = "Ожидаем координаты для сайта…"
        manager.requestWhenInUseAuthorization(); manager.startUpdatingLocation()
    }
    func stop(reason: String = "user_stop") {
        guard active else { return }
        active = false; generation = UUID(); manager.stopUpdatingLocation()
        message = "Передача рабочего положения выключена"
        guard let prior = token else { return }; token = nil
        let payload = StaffLocationStopRequest(deviceID: deviceID, sequence: sequence(), reason: reason)
        Task { do { _ = try await StaffAccountAPI().stopLocation(accountToken: prior, payload: payload) }
            catch { if !active { message = "Передача остановлена на телефоне. Серверное подтверждение недоступно; последнее положение устареет через 90 секунд." } } }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if active && [.denied, .restricted].contains(manager.authorizationStatus) { stop(reason: "permission_denied") }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Нет свежего GPS для сайта. Локальные инструменты доступны." }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, !sending, Date().timeIntervalSince(lastSent) >= 20, let fix = locations.last,
              fix.horizontalAccuracy >= 0, abs(fix.timestamp.timeIntervalSinceNow) < 30 else { return }
        guard let account, let token, (try? account.accountToken()) == token else { stop(reason: "logout"); return }
        if fix.sourceInformation?.isSimulatedBySoftware == true { message = "Для рабочего подключения нужен реальный GPS; симуляция отклонена."; return }
        let attempt = generation, next = sequence()
        let payload = StaffLocationRequest(deviceID: deviceID, sequence: next,
            accuracyAuthorization: manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
            observedAt: ISO8601DateFormatter().string(from: fix.timestamp), latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude, accuracyMeters: fix.horizontalAccuracy, simulatedBySoftware: false)
        sending = true; lastSent = Date()
        Task {
            defer { sending = false }
            do {
                let result = try await StaffAccountAPI().location(accountToken: token, payload: payload)
                guard active, generation == attempt else { return }
                guard result.ok, result.location.deviceID == deviceID, result.location.sequence == next,
                      result.workAllowed, result.location.workAllowed else { throw StaffAccountError.workLocationRequired }
                message = "Сайт подтвердил рабочее положение · GPS ±\(Int(fix.horizontalAccuracy)) м"
            } catch { if generation == attempt { message = error.localizedDescription } }
        }
    }
}

struct WebsiteWorkLocationSection: View {
    @EnvironmentObject var account: WebsiteAccount
    @EnvironmentObject var workLocation: WebsiteWorkLocation
    var body: some View {
        Section("Рабочее подключение") {
            Toggle("Передавать рабочее положение на сайт", isOn: Binding(get: { workLocation.active }, set: { if $0 { workLocation.start(account) } else { workLocation.stop() } }))
                .disabled(!account.hasSavedLogin)
            Text(workLocation.message).font(.footnote)
            Text("Сайт требует свежие координаты для работы с заданиями. Передача действует, пока приложение открыто; координаты не отправляются x0.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
