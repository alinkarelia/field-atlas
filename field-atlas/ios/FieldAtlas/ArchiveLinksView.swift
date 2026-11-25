import SwiftUI
import UniformTypeIdentifiers
import FieldCore

struct ArchivePerson:Decodable {var id:String;var key:String;var name:String;var source:String;var birth:String;var death:String;var place:String;var url:String;var synthetic:Bool}
struct ArchiveDecision:Decodable {var effectiveState:String;var evidence:String;var state:String}
struct ArchiveCandidate:Decodable,Identifiable {var id:String;var slot:Int;var person:ArchivePerson;var token:String;var reasons:[String];var conflicts:[String];var link:ArchiveDecision?}
struct ArchiveReading:Decodable {var name:String;var birth:String;var death:String}
struct ArchiveGroup:Decodable {var slot:Int;var reading:ArchiveReading;var candidates:[ArchiveCandidate]}
struct ArchiveComparison:Decodable {var recordId:String;var groups:[ArchiveGroup];var peopleCount:Int}
struct ImportReceipt:Decodable {var imported:Int}

struct ArchiveLinksView:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var sync:SyncClient
    let project:FieldProject
    @State private var recordId=""
    @State private var notice=""
    @State private var busy=false
    @State private var importing=false
    @State private var comparison:ArchiveComparison?
    @State private var evidence:[String:String]=[:]
    private var records:[Observation]{store.records(project.id).filter{$0.kind=="grave"}}
    var body:some View{
        Form{
            Section{Text("Свяжите человека на плите с существующей карточкой. Исходники и история решений сохраняются. Объединение карточек людей выполняется отдельно на сайте.").font(.footnote);Button("Импорт карточек людей JSON"){importing=true}}
            Section("Захоронение"){Picker("Карточка",selection:$recordId){Text("Выберите").tag("");ForEach(records){r in Text(r.title.isEmpty ? String(r.id.prefix(8)):r.title).tag(r.id)}};Button("Сравнить с архивом"){Task{await compare()}}.disabled(recordId.isEmpty||busy)}
            if !notice.isEmpty{Section{Text(notice).font(.footnote)}}
            if busy{ProgressView()}
            if let comparison{
                Section{Text("В локальной копии архива: \(comparison.peopleCount). Совпадение всегда проверяет человек.").font(.footnote)}
                ForEach(comparison.groups,id:\.slot){group in
                    Section(group.reading.name.isEmpty ? "Неизвестное имя":group.reading.name){
                        Text("На плите: \(group.reading.birth) — \(group.reading.death)").font(.footnote)
                        if group.candidates.isEmpty{Text("Подходящих карточек пока нет").foregroundStyle(.secondary)}
                        ForEach(group.candidates){candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }
        }.navigationTitle("Связи с архивом")
        .onChange(of:recordId){_,_ in comparison=nil}
        .fileImporter(isPresented:$importing,allowedContentTypes:[.json]){result in Task{
            do{let url=try result.get();let scope=url.startAccessingSecurityScopedResource();defer{if scope{url.stopAccessingSecurityScopedResource()}};let data=try Data(contentsOf:url);guard data.count<=2*1024*1024 else{throw NetworkProblem.response(413,"Файл больше 2 МБ")};let result:ImportReceipt=try await sync.request("/api/identity/import",method:"POST",data:data);notice="Импортировано \(result.imported) карточек";comparison=nil}catch{notice=error.localizedDescription}
        }}
    }
    private func candidateRow(_ candidate:ArchiveCandidate)->some View {
                            VStack(alignment:.leading,spacing:12){
                                Text(candidate.person.name).font(.headline)
                                Text("\(candidate.person.birth) — \(candidate.person.death) · \(candidate.person.place)").font(.subheadline)
                                Text(candidate.person.synthetic ? "Учебные данные":candidate.person.source).font(.caption).foregroundStyle(.secondary)
                                if let url=URL(string:candidate.person.url),url.scheme=="https"{Link("Карточка источника ↗",destination:url)}
                                ForEach(candidate.reasons,id:\.self){Text($0).font(.footnote)}
                                ForEach(candidate.conflicts,id:\.self){Text($0).font(.footnote).foregroundStyle(.orange)}
                                if let link=candidate.link{Text(stateName(link.effectiveState)).font(.subheadline.weight(.semibold));Text(link.evidence).font(.footnote)}
                                TextField("Основание решения",text:Binding(get:{evidence[candidate.id] ?? candidate.link?.evidence ?? ""},set:{evidence[candidate.id]=$0}),axis:.vertical)
                                Button("Подтвердить связь"){Task{await decide(candidate,state:"confirmed")}}.disabled(busy || !candidate.conflicts.isEmpty || candidate.link?.effectiveState == "confirmed")
                                Button(candidate.link?.state=="confirmed" ? "Отозвать связь":"Другой человек"){Task{await decide(candidate,state:candidate.link?.state=="confirmed" ? "revoked":"rejected")}}.disabled(busy)
                            }.padding(.vertical,10)
    }
    private func stateName(_ value:String)->String{["confirmed":"Связь подтверждена","rejected":"Другой человек","revoked":"Связь отозвана","needs_review":"Сведения изменились — нужна проверка"][value] ?? value}
    private func compare()async{
        guard !busy else{return};busy=true;defer{busy=false}
        guard let r=records.first(where:{$0.id==recordId}),!r.dirty else{notice="Передайте последние изменения карточки в разделе «Передача»";comparison=nil;return}
        do{comparison=try await sync.request("/api/identity/candidates?recordId=\(recordId)");notice=""}catch{notice=error.localizedDescription}
    }
    private func decide(_ candidate:ArchiveCandidate,state:String)async{
        guard !busy else{return};busy=true
        do{
            guard records.first(where:{$0.id==recordId})?.dirty==false else{throw NetworkProblem.response(409,"Сначала передайте изменённую карточку")}
            let body=try JSONSerialization.data(withJSONObject:["recordId":recordId,"slot":candidate.slot,"personKey":candidate.person.key,"token":candidate.token,"state":state,"evidence":evidence[candidate.id] ?? candidate.link?.evidence ?? ""])
            let _:ArchiveDecision=try await sync.request("/api/identity/decide",method:"POST",data:body)
            busy=false;await compare()
        }catch{notice=error.localizedDescription;busy=false}
    }
}
