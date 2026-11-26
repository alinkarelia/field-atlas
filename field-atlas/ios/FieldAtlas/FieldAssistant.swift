import SwiftUI
import FieldCore

struct FieldAssistantResult: Codable {
    let id: String
    let text: String
    let mode: String
    let verified: Bool
    let notice: String
    let source_sha256: String?
    var original_source_sha256:String? = nil
}

@MainActor final class FieldAssistant: ObservableObject {
    @Published var busy = false
    @Published var message = "Выберите, с чем помочь."
    @Published var result: FieldAssistantResult?
    private var requestID = UUID().uuidString
    private var fingerprint = ""
    private var operation: Task<Void, Never>?
    func cancel() { operation?.cancel() }
    func ask(question: String, context: String, taskID: String, photo: PhotoAttachment?,
             project: FieldProject, store: AppStore, account: WebsiteAccount) {
        guard !busy else { return }
        busy = true; result = nil; message = photo == nil ? "x0 готовит подсказку…" : "x0 читает выбранную надпись…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let token = try account.accountToken()
                var payload: [String: Any] = ["task_id": taskID, "mode": photo == nil ? "advice" : "ocr",
                    "question": question, "context": context, "consent": true]
                if let photo {
                    guard let file = store.assetURL(photo.id) else { throw CocoaError(.fileReadNoSuchFile) }
                    let raw = try Data(contentsOf: file)
                    let prepared=try AssistantImage.prepare(raw,hash:photo.sha256)
                    if prepared.transformed{_ = try store.saveAsset(prepared.data,projectId:project.id,mime:"image/jpeg",extension:"jpg")}
                    payload["image_base64"] = prepared.data.base64EncodedString();payload["source_sha256"] = prepared.sourceHash
                }
                let digest = SiteTransfer.digest(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                if digest != fingerprint { requestID = UUID().uuidString; fingerprint = digest }
                payload["id"] = requestID
                var request = URLRequest(url: try StaffIdentityPolicy.nativeURL(relativePath: "atlas/assistant"))
                request.httpMethod = "POST"; request.timeoutInterval = 170
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (body, response) = try await TeamHTTP.session.data(for: request)
                try Task.checkCancellation()
                guard (try? account.accountToken()) == token else { throw StaffAccountError.accountExpired }
                guard let http = response as? HTTPURLResponse, body.count <= 128 * 1024 else { throw StaffAccountError.invalidResponse }
                guard http.statusCode == 200 else {
                    if http.statusCode == 409 { throw SiteTransferError.message("Предыдущий запрос ещё выполняется или прерван. Попробуйте проверить ответ позже; повторная обработка не запускается автоматически.") }
                    if http.statusCode == 404 { throw SiteTransferError.message("Задание или запрос недоступны. Обновите вход и выберите действующее задание сайта.") }
                    if http.statusCode == 422 { throw SiteTransferError.message("Сайт не принял вопрос или снимок. Проверьте выбранное задание и размер фото.") }
                    throw StaffAccountError.http(http.statusCode)
                }
                var answer = try JSONDecoder().decode(FieldAssistantResult.self, from: body)
                guard answer.id == requestID, !answer.verified, answer.text.count <= 32000,
                      answer.mode == (photo == nil ? "advice" : "ocr"),
                      answer.source_sha256 == (payload["source_sha256"] as? String) else { throw StaffAccountError.invalidResponse }
                answer.original_source_sha256=photo?.sha256
                _ = try store.saveAsset(store.encoder.encode(answer), projectId: project.id, mime: "application/json", extension: "json")
                result = answer; message = "Ответ сохранён на устройстве."
            } catch is CancellationError { message = "Ожидание остановлено. Сервер мог уже получить запрос." }
            catch { message = error.localizedDescription }
        }
    }
    func newAttempt() { if !busy { requestID = UUID().uuidString; result = nil; message = "Можно отправить новый запрос." } }
}

struct FieldAssistantView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var account: WebsiteAccount
    @Environment(\.dismiss) private var dismiss
    @StateObject private var assistant = FieldAssistant()
    @State private var taskID = ""
    @State private var question = ""
    @State private var consent = false
    @State private var showAccount = false
    let project: FieldProject
    var context = ""
    var photo: PhotoAttachment? = nil
    var onReading: ((String, String) -> Void)? = nil
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(photo == nil ? "x0 · помощник в поле" : "x0 · чтение надписи", systemImage: "sparkles")
                        .font(.headline)
                    Text(photo == nil ? "Вопрос по съёмке, качеству данных или следующему действию." : "Будет отправлен выбранный снимок или его копия до 6 МБ для чтения. Оригинал остаётся в карточке. Результат нужно сверить с плитой.").font(.footnote)
                    if let photo, let url = store.assetURL(photo.id), let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                    }
                    if !context.isEmpty { DisclosureGroup("Контекст для x0") { Text(context).font(.caption) } }
                }
                Section("1 · Подключить ответ x0") {
                    Text("Войдите в учётную запись сайта, выберите доступное вам задание и включите рабочее положение ниже. Это условия доступа сайта. Без подключения карта, карточки и фотографии работают локально.").font(.footnote).foregroundStyle(.secondary)
                    Button(account.context?.user.displayName ?? "Войти через сайт") { showAccount = true }
                    if let tasks = account.context?.tasks {
                        Picker("Задание", selection: $taskID) {
                            Text("Выберите задание").tag("")
                            ForEach(tasks) { Text($0.title).tag($0.id) }
                        }
                    }
                }
                WebsiteWorkLocationSection()
                Section("2 · Вопрос и выбранные материалы") {
                    TextField("Что нужно проверить?", text: $question, axis: .vertical).lineLimit(3...7)
                    if photo == nil {
                        Button("Что делать дальше на кладбище?") { question = "Объясни следующий шаг работы на кладбище по контексту: граница, пути, метки, карточка захоронения и фотографии." }
                        Button("Как доснять пропущенный участок?") { question = "Как доснять пропущенный участок и обеспечить перекрытие с соседним сектором?" }
                        Button("Как прочитать стёртую надпись?") { question = "Как безопасно снять плохо читаемую могильную плиту, не повреждая её?" }
                    }
                    Toggle("Отправить выбранный вопрос и материалы x0", isOn: $consent)
                    Button("Спросить x0") { assistant.ask(question: question, context: context, taskID: taskID, photo: photo, project: project, store: store, account: account) }
                        .disabled(assistant.busy || account.context == nil || !consent || taskID.isEmpty || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4000)
                        .accessibilityIdentifier("field-assistant-send")
                }.disabled(assistant.busy)
                Section {
                    Text(assistant.message).font(.footnote)
                    if assistant.busy { ProgressView("Обработка на сервере"); Button("Прекратить ожидание") { assistant.cancel() } }
                    if let result = assistant.result {
                        Text(result.notice).font(.caption).foregroundStyle(.orange)
                        Text(result.text).textSelection(.enabled)
                        if let source = result.source_sha256, let onReading {
                            Button("Вставить как непроверенное чтение") { onReading(result.text, result.original_source_sha256 ?? source); dismiss() }
                        }
                    } else if !assistant.busy {
                        Button("Подготовить новый запрос") { assistant.newAttempt() }.font(.footnote)
                    }
                }
            }.navigationTitle("Помощник x0").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("К работе") { dismiss() } } }
                .task { if photo != nil { question = "Прочитай видимый текст. Нечитаемые места не дополняй." }; await account.refresh(); if taskID.isEmpty,let tasks=account.context?.tasks,tasks.count==1 {taskID=tasks[0].id} }
                .sheet(isPresented: $showAccount) { WebsiteAccountView() }
        }
    }
}
