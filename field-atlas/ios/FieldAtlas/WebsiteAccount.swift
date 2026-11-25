import SwiftUI
import Security
import FieldCore

/// Only the revocable website bearer is persisted, never a password, browser
/// cookie, authorization code or PKCE verifier. This entry stays on this device.
struct WebsiteKeychain {
    private var service: String {
        var name = (Bundle.main.bundleIdentifier ?? "ru.archiverf.fieldatlas") + ".website-account"
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"], UUID(uuidString: test) != nil {
            name += ".test." + test
        }
        #endif
        return name
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "archiverf.ru", kSecAttrSynchronizable as String: false]
    }
    func read() throws -> StaffAccountCredentials? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw WebsiteKeychainError.unavailable(status) }
        return try JSONDecoder().decode(StaffAccountCredentials.self, from: data)
    }
    func save(_ value: StaffAccountCredentials) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WebsiteKeychainError.unavailable(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WebsiteKeychainError.unavailable(status) }
    }
}

enum WebsiteKeychainError: LocalizedError {
    case unavailable(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable(errSecInteractionNotAllowed):
            return "Разблокируйте устройство и повторите вход."
        case .unavailable(errSecMissingEntitlement):
            return "Подпись приложения не даёт доступа к Связке ключей. Повторно подпишите приложение с тем же Apple ID и установите обновление без удаления материалов."
        case .unavailable(let status):
            return "Не удалось открыть защищённое хранилище входа (код \(status)). Повторите попытку."
        }
    }
}

@MainActor final class WebsiteAccount: ObservableObject {
    @Published private(set) var context: StaffAccountContext?
    @Published private(set) var busy = false
    @Published private(set) var hasSavedLogin = false
    @Published private(set) var message = "Вход нужен для работы с сайтом. Съёмка доступна без интернета."
    private var credentials: StaffAccountCredentials?
    private var generation = UUID()
    private let keychain = WebsiteKeychain()
    private let api = StaffAccountAPI()
    private let browser = StaffWebAuthenticator()

    init() {
        do {
            credentials = try keychain.read()
            if let credentials {
                try credentials.validated()
                hasSavedLogin = true
                message = "Вход сохранён. Проверим доступ при подключении к сайту."
            }
        } catch StaffIdentityError.expiredSession {
            credentials = nil
            try? keychain.clear()
            message = "Срок входа истёк. Войдите на сайт снова."
        } catch {
            credentials = nil
            message = error.localizedDescription
        }
    }

    func signIn() async {
        guard !busy else { return }
        busy = true
        let attempt = UUID(); generation = attempt
        defer { if generation == attempt { busy = false } }
        do {
            let request = try StaffIdentityPolicy.makePKCE(verifier: StaffWebAuthenticator.secureRandom(), state: StaffWebAuthenticator.secureRandom())
            message = "Подтвердите вход в защищённом окне сайта."
            let callback = try await browser.authorize(request.authorizationURL)
            try requireCurrent(attempt)
            let code = try StaffIdentityPolicy.validateCallback(callback, expectedState: request.state)
            let newCredentials = try await api.exchange(code: code, verifier: request.verifier)
            try newCredentials.validated()
            let newContext = try await api.context(accountToken: newCredentials.accessToken)
            try requireCurrent(attempt)
            try newContext.validated(accountExpiresAt: newCredentials.expiry!)
            // Publish the account only after durable protected storage succeeds.
            try keychain.save(newCredentials)
            credentials = newCredentials; context = newContext; hasSavedLogin = true
            message = "Вход выполнен. Доступ определяется вашей учётной записью сайта."
        } catch {
            if generation == attempt { message = error.localizedDescription }
        }
    }

    func refresh() async {
        guard !busy, let credentials else { return }
        busy = true
        let attempt = generation
        defer { if generation == attempt { busy = false } }
        do {
            try credentials.validated()
            let result = try await api.context(accountToken: credentials.accessToken)
            try requireCurrent(attempt)
            try result.validated(accountExpiresAt: credentials.expiry!)
            context = result
            message = "Учётная запись подтверждена сайтом."
        } catch {
            guard generation == attempt else { return }
            context = nil
            if case StaffAccountError.http(401) = error { clearLocal() }
            if case StaffIdentityError.expiredSession = error { clearLocal() }
            message = error.localizedDescription
        }
    }

    func cancelSignIn() { browser.cancel() }

    func signOut() async {
        guard !busy else { return }
        busy = true; generation = UUID()
        let prior = credentials
        do {
            if let prior { try await api.logout(accountToken: prior.accessToken) }
            try keychain.clear()
            credentials = nil; context = nil; hasSavedLogin = false
            message = "Вы вышли. Проекты и исходные файлы остались на устройстве."
        } catch {
            // Keep a failed logout visible; never say a server session was revoked.
            message = "Выход не подтверждён. \(error.localizedDescription) Повторите при подключении к сети."
        }
        busy = false
    }

    private func clearLocal() {
        credentials = nil; context = nil; hasSavedLogin = false
        try? keychain.clear()
    }
    private func requireCurrent(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }
}

struct WebsiteAccountView: View {
    @EnvironmentObject var account: WebsiteAccount
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Семейный архив: Живая память", systemImage: "person.crop.circle")
                        .font(.headline)
                    Text("Одна учётная запись для сайта и полевой работы.")
                        .foregroundStyle(.secondary)
                    Text("Съёмка и карточки доступны без входа и интернета.")
                        .font(.footnote).accessibilityIdentifier("website-offline-work")
                }
                if let context = account.context {
                    Section("Ваша учётная запись") {
                        LabeledContent("Имя", value: context.user.displayName)
                        if !context.user.email.isEmpty { LabeledContent("Почта", value: context.user.email) }
                        LabeledContent("Доступных заданий", value: String(context.tasks.count))
                        Button("Обновить доступ") { Task { await account.refresh() } }
                            .disabled(account.busy)
                    }
                    if !context.tasks.isEmpty {
                        Section("Задания сайта") {
                            ForEach(context.tasks) { task in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.title)
                                    if let workspace = task.workspaceTitle { Text(workspace).font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }
                Section {
                    Text(account.message).font(.footnote).accessibilityIdentifier("website-account-status")
                    if account.busy { ProgressView("Связь с сайтом") }
                    if account.context == nil {
                        Button { Task { await account.signIn() } } label: {
                            Label("Войти через сайт", systemImage: "person.badge.key")
                                .frame(minHeight: 36)
                        }.accessibilityIdentifier("website-sign-in").disabled(account.busy)
                        if account.hasSavedLogin {
                            Button("Проверить сохранённый вход") { Task { await account.refresh() } }.disabled(account.busy)
                        }
                    }
                    if account.hasSavedLogin {
                        Button("Выйти из учётной записи", role: .destructive) { Task { await account.signOut() } }
                            .disabled(account.busy)
                    }
                }
                Section {
                    Text("Окно входа принадлежит archiverf.ru. Приложение хранит защищённую сессию в Связке ключей iOS. Исходные материалы не отправляются при входе автоматически.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Учётная запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { await account.refresh() }
        }
    }
}
