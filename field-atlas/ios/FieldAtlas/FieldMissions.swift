import SwiftUI
import CoreLocation
import FieldCore

struct MissionIndex: Codable, Identifiable {
    var id: String
    var projectID: String
    var title: String
    var mode: TravelMode
    var status: String
}

@MainActor final class FieldMissionRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var index: [MissionIndex] = []
    @Published private(set) var summary = MissionSummary(mission: FieldMission(projectId:"",title:"",mode:.timed),now:0)
    @Published private(set) var selectedID: String?
    @Published var message = "Выберите пеший маршрут, поездку или замер времени."
    @Published private(set) var speed: Double?
    private var store: AppStore?
    private var mission: FieldMission?
    private let manager = CLLocationManager()
    private var handle: FileHandle?
    private var timer: Timer?
    private var lastFix = Date.distantPast
    var selected: MissionIndex? { index.first { $0.id == selectedID } }
    var active: Bool { summary.status == "running" }
    override init() { super.init(); manager.delegate=self; manager.desiredAccuracy=kCLLocationAccuracyBest; manager.distanceFilter=kCLDistanceFilterNone; manager.pausesLocationUpdatesAutomatically=false }

    func configure(_ store: AppStore) {
        guard self.store == nil else { return }; self.store=store
        do {
            let url=store.root.appendingPathComponent("mission-index.json")
            if FileManager.default.fileExists(atPath:url.path) { index=try JSONDecoder().decode([MissionIndex].self,from:Data(contentsOf:url)) }
            if let entry=index.last(where:{$0.status != "completed"}) { try load(entry.id); if active { try append(MissionEvent("interrupt",time:mission?.events.last?.time ?? Date().timeIntervalSince1970)); message="Запись была прервана. Сохранённый трек восстановлен; нажмите «Продолжить»." } }
        } catch { message="Не удалось открыть журнал задания: \(error.localizedDescription). Исходники сохранены." }
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in
            guard let self else{return};self.summary.updateTime(Date().timeIntervalSince1970)
            if Date().timeIntervalSince(self.lastFix)>10{self.speed=nil}
        }}
    }
    private func file(_ id:String)throws->URL {
        guard UUID(uuidString:id) != nil,let store else{throw CocoaError(.fileReadCorruptFile)}
        return store.root.appendingPathComponent("mission-"+id+".jsonl")
    }
    private func saveIndex()throws {
        guard let store else{return}
        try store.encoder.encode(index).write(to:store.root.appendingPathComponent("mission-index.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func create(project:FieldProject,title:String,mode:TravelMode,assignment:String) {
        guard !index.contains(where:{$0.status != "completed"}) else{message="Сначала завершите текущее задание.";return}
        do {
            let value=FieldMission(projectId:project.id,title:title.trimmingCharacters(in:.whitespacesAndNewlines),mode:mode,assignmentReference:assignment)
            guard !value.title.isEmpty,let store else{return}
            var header=try store.encoder.encode(value);header.append(10)
            try header.write(to:file(value.id),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            index.append(MissionIndex(id:value.id,projectID:project.id,title:value.title,mode:mode,status:"planned"));try saveIndex()
            try load(value.id);try append(MissionEvent("start",time:Date().timeIntervalSince1970));beginGPS(mode)
        } catch { stopOnError(error) }
    }
    func open(_ id:String) { guard !active else{return};do{try load(id)}catch{stopOnError(error)} }
    private func load(_ id:String)throws {
        let url=try file(id),data=try Data(contentsOf:url)
        guard data.count<=64*1024*1024,let lastNewline=data.lastIndex(of:10) else{throw CocoaError(.fileReadCorruptFile)}
        // Preserve any interrupted tail before truncating it; never overwrite the original journal wholesale.
        if lastNewline+1<data.count {
            try data.suffix(from:lastNewline+1).write(to:url.appendingPathExtension("recovery-"+UUID().uuidString),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            let repair=try FileHandle(forWritingTo:url);try repair.truncate(atOffset:UInt64(lastNewline+1));try repair.synchronize();try repair.close()
        }
        let lines=data.prefix(lastNewline+1).split(separator:10)
        guard let header=lines.first else{throw CocoaError(.fileReadCorruptFile)}
        var value=try JSONDecoder().decode(FieldMission.self,from:Data(header))
        guard value.id==id,value.schema=="field-mission-v1" else{throw CocoaError(.fileReadCorruptFile)}
        for line in lines.dropFirst(){value.events.append(try JSONDecoder().decode(MissionEvent.self,from:Data(line)))}
        try handle?.close();handle=try FileHandle(forWritingTo:url);try handle?.seekToEnd()
        mission=value;selectedID=id;summary=value.summary(at:Date().timeIntervalSince1970)
    }
    private func append(_ event:MissionEvent)throws {
        guard let store,let handle,let mode=mission?.mode,let id=mission?.id else{throw CocoaError(.fileWriteUnknown)}
        guard (mission?.events.count ?? 0)<200000 || ["finish","pause","interrupt"].contains(event.kind) else{throw SiteTransferError.message("Журнал достиг предела. Сохраните его и начните отдельный маршрут.")}
        var bytes=try store.encoder.encode(event);bytes.append(10)
        try handle.write(contentsOf:bytes);try handle.synchronize()
        mission?.events.append(event);summary.apply(event,mode:mode)
        if let i=index.firstIndex(where:{$0.id==id}),index[i].status != summary.status { index[i].status=summary.status;try saveIndex() }
    }
    private func beginGPS(_ mode:TravelMode) {
        guard mode != .timed else{message="Идёт замер времени без GPS.";return}
        manager.activityType=mode == .driving ? .automotiveNavigation:.fitness
        manager.allowsBackgroundLocationUpdates=true;manager.showsBackgroundLocationIndicator=true
        manager.requestWhenInUseAuthorization();manager.startUpdatingLocation();lastFix = .distantPast
        message="GPS записывается, в том числе при блокировке экрана. Для паузы используйте кнопку задания."
    }
    func pauseOrResume() {
        guard let mode=mission?.mode,summary.status != "completed" else{return}
        do {
            if active{try append(.init("pause",time:Date().timeIntervalSince1970));manager.stopUpdatingLocation();speed=nil;message="Пауза. Её время не входит во время записи."}
            else{try append(.init("resume",time:Date().timeIntervalSince1970));beginGPS(mode)}
        }catch{stopOnError(error)}
    }
    func checkpoint(_ text:String) {
        guard let mission,summary.status != "completed" else{return}
        do{try append(.init("checkpoint",time:Date().timeIntervalSince1970,fix:Date().timeIntervalSince(lastFix)<10 ? summary.segments.last?.last:nil,text:text.isEmpty ? "Контрольная точка":String(text.prefix(1000))));message="Контрольная точка сохранена в задании «\(mission.title)»."}catch{stopOnError(error)}
    }
    func finish() {
        guard mission != nil,summary.status != "completed" else{return}
        do { try append(.init("finish",time:Date().timeIntervalSince1970));manager.stopUpdatingLocation();speed=nil;try export();message="Задание завершено. GPX, журнал и карточка результата сохранены." }
        catch{stopOnError(error)}
    }
    func retryExport() {do{try export();message="Результат сохранён в проекте."}catch{message=error.localizedDescription}}
    private func export()throws {
        guard let value=mission,let store,summary.status=="completed" else{return}
        let json=try store.saveAsset(store.encoder.encode(value),projectId:value.projectId,mime:"application/json",extension:"json")
        let gpx=try store.saveAsset(Data(value.gpx.utf8),projectId:value.projectId,mime:"application/gpx+xml",extension:"gpx")
        var record=store.records(value.projectId).first(where:{$0.id==value.id}) ?? Observation(projectId:value.projectId,kind:"object")
        record.id=value.id;record.title=value.title;record.needsReview=true;record.status="complete"
        record.fieldMissionID=value.id;record.sourceAssetIDs=[json.id,gpx.id]
        record.comments="\(value.mode.title). Запись: \(Self.duration(summary.recording)). Общее время: \(Self.duration(summary.elapsed)). Путь: \(String(format:"%.0f",summary.distance)) м. Средняя в движении: \(String(format:"%.1f",(summary.averageMovingSpeed ?? 0)*3.6)) км/ч. Разрывы: \(summary.gaps). Задание сайта: \(value.assignmentReference.isEmpty ? "не связано":value.assignmentReference)."
        if let first=summary.segments.first?.first{record.origin=GeoOrigin(lat:first.lat,lon:first.lon);record.point=[0,0];record.locationMethod="gps";record.locationAccuracy=first.accuracy}
        try store.save(record)
    }
    private func stopOnError(_ error:Error) {
        manager.stopUpdatingLocation();speed=nil
        if summary.status=="running"{summary.apply(.init("interrupt",time:mission?.events.last?.time ?? Date().timeIntervalSince1970),mode:mission?.mode ?? .timed)}
        message="Запись остановлена: \(error.localizedDescription). Журнал сохранён до последнего подтверждённого события."
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){if [.denied,.restricted].contains(manager.authorizationStatus){message="GPS запрещён. Время записывается; маршрут не определён."}}
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error){guard active else{return};do{try append(.init("gap",time:Date().timeIntervalSince1970));speed=nil;message="Потерян GPS. Время идёт, разрыв отмечен."}catch{stopOnError(error)}}
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard active,let value=locations.last,value.timestamp.timeIntervalSince(lastFix)>=2,abs(value.timestamp.timeIntervalSinceNow)<10 else{return}
        if value.sourceInformation?.isSimulatedBySoftware == true{message="Симулированный GPS не записан.";return}
        let fix=RouteFix(time:value.timestamp.timeIntervalSince1970,lat:value.coordinate.latitude,lon:value.coordinate.longitude,accuracy:value.horizontalAccuracy,speed:value.speed>=0 ? value.speed:nil)
        do { try append(.init("fix",time:Date().timeIntervalSince1970,fix:fix));lastFix=value.timestamp
            speed=fix.valid && fix.accuracy<=(mission?.mode == .driving ? 30:15) ? fix.speed:nil
        }catch{stopOnError(error)}
    }
    static func duration(_ value:Double)->String{let s=max(0,Int(value));return String(format:"%02d:%02d:%02d",s/3600,s/60%60,s%60)}
}

struct FieldMissionsView: View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var account:WebsiteAccount
    @EnvironmentObject var recorder:FieldMissionRecorder
    @Environment(\.dismiss) private var dismiss
    let project:FieldProject
    @State private var title=""
    @State private var mode=TravelMode.walking
    @State private var assignment=""
    @State private var note=""
    @State private var confirmFinish=false
    var body:some View {
        NavigationStack { Form {
            if let current=recorder.selected {
                Section(current.title) {
                    LabeledContent("Состояние",value:["running":"Запись","paused":"Пауза","interrupted":"Прервано","completed":"Завершено"][recorder.summary.status] ?? "Готово")
                    LabeledContent("Время записи",value:FieldMissionRecorder.duration(recorder.summary.recording))
                    LabeledContent("Общее время",value:FieldMissionRecorder.duration(recorder.summary.elapsed))
                    LabeledContent("Пройдено",value:String(format:"%.0f м",recorder.summary.distance))
                    if current.mode != .timed {
                        LabeledContent("Скорость сейчас",value:recorder.speed.map{String(format:"%.1f км/ч",$0*3.6)} ?? "Нет свежего GPS")
                        LabeledContent("Средняя в движении",value:recorder.summary.averageMovingSpeed.map{String(format:"%.1f км/ч",$0*3.6)} ?? "—")
                        LabeledContent("Разрывы / отклонённые точки",value:"\(recorder.summary.gaps) / \(recorder.summary.rejectedFixes)")
                    }
                    if recorder.summary.status != "completed" {
                        Button(recorder.active ? "Пауза":"Продолжить"){recorder.pauseOrResume()}.accessibilityIdentifier("mission-pause")
                        TextField("Комментарий к контрольной точке",text:$note)
                        Button("Отметить контрольную точку"){recorder.checkpoint(note);note=""}
                        Button("Завершить задание"){confirmFinish=true}.accessibilityIdentifier("mission-finish")
                    } else { Button("Сохранить / повторить экспорт результата"){recorder.retryExport()} }
                }
            }
            Section { Text(recorder.message).font(.footnote) }
            if !recorder.index.contains(where:{$0.status != "completed"}) {
                Section("Новое полевое задание") {
                    TextField("Название задания",text:$title).accessibilityIdentifier("mission-title")
                    Picker("Режим",selection:$mode){ForEach(TravelMode.allCases){Text($0.title).tag($0)}}.accessibilityIdentifier("mission-mode")
                    Picker("Связь с заданием сайта",selection:$assignment){Text("Локальное задание").tag("");ForEach(account.context?.tasks ?? []){Text($0.title).tag($0.id)}}
                    Button("Начать задание"){recorder.create(project:project,title:title,mode:mode,assignment:assignment)}
                        .disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("mission-start")
                    Text("Для поездки запустите запись до движения. Пропуски GPS сохраняются как разрывы. В режиме замера времени GPS не используется.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Журнал проекта") {
                ForEach(recorder.index.filter{$0.projectID==project.id}.reversed()) { item in
                    Button{recorder.open(item.id)}label:{VStack(alignment:.leading){Text(item.title);Text(item.mode.title+" · "+(item.status=="completed" ? "Завершено":"Не завершено")).font(.caption)}}.disabled(recorder.active)
                }
            }
        }.navigationTitle("Полевые задания").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.confirmationAction){Button("К работе"){dismiss()}}}
            .confirmationDialog("Завершить запись и сохранить результат?",isPresented:$confirmFinish,titleVisibility:.visible){Button("Завершить и сохранить"){recorder.finish()};Button("Продолжать запись",role:.cancel){}}
        }.onAppear{recorder.configure(store)}
    }
}
