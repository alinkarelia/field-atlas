import SwiftUI
import CryptoKit
import FieldCore

struct SiteAssetProgress: Codable {
    let id: String
    let byteCount: Int
    let uploadedBytes: Int
    let verified: Bool
    func validate(id expected: String, size: Int, offset: Int? = nil) throws {
        guard id.lowercased() == expected.lowercased(), byteCount == size,
              (0...size).contains(uploadedBytes), !verified || uploadedBytes == size,
              offset == nil || uploadedBytes == offset else { throw StaffAccountError.invalidResponse }
    }
}

struct SitePackageProgress: Decodable {
    let captureID: String
    let projectID: String
    let state: String
    let assets: [SiteAssetProgress]
    let chunkSize: Int
}

/// Separate destination receipts: a sandbox acknowledgement is never a site receipt.
struct SiteTransferLedger: Codable {
    var ownerID: String
    var taskID: String
    var projectID = UUID().uuidString.lowercased()
    var title: String
    var complete: [String] = []
    var snapshotHash: String?
    var snapshotID: String?
    var snapshotCreatedAt: Double?
}

enum SiteTransferError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}

@MainActor final class SiteTransfer: ObservableObject {
    @Published var busy = false
    @Published var progress = 0.0
    @Published var message = "Выберите задание сайта для этого проекта."
    private var operation: Task<Void, Never>?
    private var expectedOwner: String?

    func cancel() { operation?.cancel() }
    func start(project: FieldProject, taskID: String, store: AppStore, account: WebsiteAccount) {
        guard !busy else { return }
        busy = true
        operation = Task {
            defer { busy = false; operation = nil; expectedOwner = nil }
            do { try await transfer(project: project, taskID: taskID, store: store, account: account) }
            catch is CancellationError { message = "Передача приостановлена. Можно продолжить с принятой части файла." }
            catch { message = error.localizedDescription + " Исходники сохранены на устройстве." }
        }
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 runtime: StaffRuntimeCredentials, account: WebsiteAccount,
                 binary: Bool = false) async throws -> Data {
        _ = try account.accountToken()
        guard account.context?.user.id == expectedOwner else { throw StaffAccountError.accountExpired }
        guard let expiry = runtime.expiry, expiry > Date(), path.hasPrefix("v1/"),
              !path.contains(".."), !path.contains("#") else { throw StaffAccountError.accountExpired }
        let base = try StaffIdentityPolicy.trustedRuntimeBaseURL(runtime.baseURL)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.path.hasPrefix("/atlas/v1/") else { throw StaffAccountError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 90
        request.setValue("Bearer " + runtime.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type") }
        try Task.checkCancellation()
        let (data, response) = try await TeamHTTP.session.data(for: request)
        try Task.checkCancellation()
        _ = try account.accountToken()
        guard account.context?.user.id == expectedOwner else { throw StaffAccountError.accountExpired }
        guard let http = response as? HTTPURLResponse, data.count <= 8 * 1024 * 1024 else { throw StaffAccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409 { throw SiteTransferError.message("Сервер обнаружил конфликт. Повторите передачу для проверки принятой части.") }
            throw StaffAccountError.http(http.statusCode)
        }
        return data
    }

    private func transfer(project: FieldProject, taskID: String, store: AppStore, account: WebsiteAccount) async throws {
        guard let owner = account.context?.user.id, !project.synthetic else {
            throw SiteTransferError.message("Войдите на сайт. Учебные проекты не передаются в рабочие задания.")
        }
        message = "Проверяем доступ к заданию…"; progress = 0
        expectedOwner = owner
        let runtime = try await account.runtime(taskID: taskID)
        let destination = Self.digest(Data((owner + "\n" + taskID + "\n" + project.id).utf8))
        let ledgerURL = store.root.appendingPathComponent("site-" + destination + ".json")
        var ledger: SiteTransferLedger
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            ledger = try JSONDecoder().decode(SiteTransferLedger.self, from: Data(contentsOf: ledgerURL))
            guard ledger.ownerID == owner, ledger.taskID == taskID else { throw StaffAccountError.invalidResponse }
        } else {
            ledger = SiteTransferLedger(ownerID: owner, taskID: taskID, title: String(project.title.prefix(150)))
            try persist(ledger, at: ledgerURL)
        }
        struct Me: Decodable { struct Membership: Decodable { let organizationID: String }; let memberships: [Membership] }
        let me = try JSONDecoder().decode(Me.self, from: await request("v1/me", runtime: runtime, account: account))
        // Runtime is task-scoped. Ambiguous memberships must not choose an unrelated destination.
        guard let scopedOrganization = runtime.context?.organization.id,
              let organization = me.memberships.first(where: { $0.organizationID == scopedOrganization }),
              UUID(uuidString: organization.organizationID) != nil else { throw StaffAccountError.invalidResponse }
        let body: [String: Any] = ["id": ledger.projectID, "organizationID": organization.organizationID,
            "name": ledger.title, "kind": project.type == .cemetery ? "cemetery" : project.type == .land ? "site" : "building",
            "coordinateReference": ["localMeters": ["frameID": project.id.lowercased()]],
            "notes": "Полевой атлас. Исходные системы координат и точность сохранены в пакетах.", "requiresIndependentReview": true]
        _ = try await request("v1/projects", method: "POST", body: JSONSerialization.data(withJSONObject: body), runtime: runtime, account: account)

        // Freeze a reviewable snapshot before network I/O. Concurrent edits belong to the next snapshot.
        let records = store.records(project.id)
        let assets = store.state.assets.filter { $0.projectId == project.id }
        let scans = store.state.scans.filter { $0.projectId == project.id }
        struct Snapshot: Encodable { let schema = "field-atlas-snapshot-v1"; let project: FieldProject; let records: [Observation]; let scans: [ScanReference]; let origin: GeoOrigin? }
        let snapshot = try store.encoder.encode(Snapshot(project: project, records: records, scans: scans, origin: store.state.origins[project.id]))
        let hash = Self.digest(snapshot)
        if ledger.snapshotHash != hash {
            ledger.snapshotHash = hash; ledger.snapshotID = UUID().uuidString.lowercased()
            ledger.snapshotCreatedAt = Date().timeIntervalSince1970 * 1000
            try persist(ledger, at: ledgerURL)
        }
        let snapshotID = ledger.snapshotID!
        let snapshotURL = store.root.appendingPathComponent("site-snapshot-" + snapshotID + ".json")
        try snapshot.write(to: snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let source = AssetEntry(id: snapshotID, projectId: project.id, filename: snapshotURL.lastPathComponent,
                                mime: "application/json", sha256: hash, size: snapshot.count)
        let queue = assets + [source]
        for (index, asset) in queue.enumerated() {
            try Task.checkCancellation()
            if ledger.complete.contains(asset.id.lowercased()) { continue }
            guard let file = asset.id == snapshotID ? snapshotURL : store.assetURL(asset.id) else { throw CocoaError(.fileReadNoSuchFile) }
            message = "Передача \(index + 1) из \(queue.count): \(asset.mime.hasPrefix("image/") ? "снимок" : "исходник")"
            try await send(asset, file: file, projectID: ledger.projectID,
                           createdAt: asset.id == snapshotID ? ledger.snapshotCreatedAt! : project.createdAt,
                           runtime: runtime, account: account)
            ledger.complete.append(asset.id.lowercased()); try persist(ledger, at: ledgerURL)
            progress = Double(index + 1) / Double(queue.count)
        }
        message = "Принято исходников: \(assets.count). Снимок карточек также сохранён в материалах выбранного задания."
        progress = 1
    }

    private func send(_ asset: AssetEntry, file: URL, projectID: String, createdAt: Double,
                      runtime: StaffRuntimeCredentials, account: WebsiteAccount) async throws {
        guard (0...512 * 1024 * 1024).contains(asset.size), UUID(uuidString: asset.id) != nil else {
            throw SiteTransferError.message("Файл превышает 512 МБ. Для передачи нужны меньшие сектора.")
        }
        let id = asset.id.lowercased(), photo = asset.mime.hasPrefix("image/")
        let captureID = Self.packageID(projectID: projectID, assetID: id)
        let manifest: [String: Any] = ["schemaVersion": 1, "id": captureID, "projectID": projectID,
            "title": photo ? "Полевой снимок" : "Полевой исходник", "createdAt": createdAt.rounded(.down),
            "timeZoneIdentifier": "UTC", "utcOffsetSeconds": 0,
            "materials": [["id": id, "sourceEntityID": id, "kind": photo ? "photo" : "project"]],
            "assets": [["id": id, "materialID": id, "relativePath": "original/" + asset.filename,
                         "mediaType": asset.mime, "byteCount": asset.size, "sha256": asset.sha256,
                         "kind": photo ? "originalPhoto" : "projectSnapshot"]]]
        let path = "v1/projects/" + projectID + "/materials"
        let data = try await request(path, method: "POST", body: JSONSerialization.data(withJSONObject: manifest), runtime: runtime, account: account)
        let package = try JSONDecoder().decode(SitePackageProgress.self, from: data)
        guard package.captureID == captureID, package.projectID == projectID, package.assets.count == 1,
              (1...1024 * 1024).contains(package.chunkSize) else { throw StaffAccountError.invalidResponse }
        var status = package.assets[0]
        try status.validate(id: id, size: asset.size)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(asset.size) else { throw CocoaError(.fileReadCorruptFile) }
        while status.uploadedBytes < asset.size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(status.uploadedBytes))
            guard let bytes = try handle.read(upToCount: min(package.chunkSize, asset.size - status.uploadedBytes)), !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let next = status.uploadedBytes + bytes.count
            let response = try await request(path + "/" + captureID + "/assets/" + id + "?offset=\(status.uploadedBytes)", method: "PUT", body: bytes, runtime: runtime, account: account, binary: true)
            status = try JSONDecoder().decode(SiteAssetProgress.self, from: response)
            try status.validate(id: id, size: asset.size, offset: next)
        }
        let final = try JSONDecoder().decode(SitePackageProgress.self, from: await request(path + "/" + captureID + "/finalize", method: "POST", body: Data("{}".utf8), runtime: runtime, account: account))
        guard final.captureID == captureID, final.projectID == projectID, final.state == "complete", final.assets.count == 1, final.assets[0].verified else { throw StaffAccountError.invalidResponse }
        try final.assets[0].validate(id: id, size: asset.size, offset: asset.size)
    }

    private func persist(_ ledger: SiteTransferLedger, at url: URL) throws {
        try JSONEncoder().encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func packageID(projectID: String, assetID: String) -> String {
        let hash = Array(digest(Data((projectID.lowercased()+":"+assetID.lowercased()).utf8)).prefix(32))
        return [String(hash[0..<8]),String(hash[8..<12]),String(hash[12..<16]),String(hash[16..<20]),String(hash[20..<32])].joined(separator:"-")
    }
}

struct SiteTransferSection: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var account: WebsiteAccount
    @EnvironmentObject var transfer: SiteTransfer
    let project: FieldProject?
    @State private var taskID = ""
    @State private var share = false
    var body: some View {
        Section("Передать на сайт") {
            if let project {
                if let context = account.context {
                    Picker("Задание", selection: $taskID) {
                        Text("Выберите задание").tag("")
                        ForEach(context.tasks) { Text($0.title).tag($0.id) }
                    }.disabled(transfer.busy)
                    Toggle("Передать карточки и оригиналы участникам задания", isOn: $share).disabled(transfer.busy)
                    Text("Проект: " + project.title).font(.footnote)
                    Button("Передать на archiverf.ru") { transfer.start(project: project, taskID: taskID, store: store, account: account) }
                        .disabled(taskID.isEmpty || !share || transfer.busy).accessibilityIdentifier("site-transfer-start")
                } else { Text("Войдите через учётную запись сайта, затем выберите задание.") }
            } else { Text("Откройте нужный проект и выберите «Передача», чтобы связать материалы с заданием.") }
            Text(transfer.message).font(.footnote).accessibilityIdentifier("site-transfer-status")
            if transfer.busy { ProgressView(value: transfer.progress); Button("Приостановить передачу") { transfer.cancel() } }
            Text("Файлы отправляются частями по 1 МБ. Подтверждение сайта сохраняется отдельно от тестовой песочницы.").font(.caption).foregroundStyle(.secondary)
        }.task { await account.refresh() }
    }
}
