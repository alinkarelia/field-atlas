import SwiftUI
import FieldCore

struct CemeteryMetadataSection:View {
    @EnvironmentObject var store:AppStore
    @Binding var draft:Observation
    let project:FieldProject
    private var parents:[Observation]{
        var seen=Set<String>()
        return store.records(project.id).filter{["sector","plot"].contains($0.kind) && $0.physicalID != draft.physicalID && seen.insert($0.physicalID).inserted}
    }
    private func string(_ path:WritableKeyPath<Observation,String?>,fallback:String="")->Binding<String>{Binding(get:{draft[keyPath:path] ?? fallback},set:{draft[keyPath:path]=$0.isEmpty ? nil:$0})}
    var body:some View{
        Section("Объект и учёт"){
            if let code=store.identityCodes[project.id]?.entities[draft.physicalID]?.code{LabeledContent("Номер объекта",value:code).textSelection(.enabled)}
            else{Text("Постоянный ID: "+draft.physicalID).font(.caption).textSelection(.enabled);Text("Короткий номер сайта появится после отправки. Этот ID уже сохранён и не изменится.").font(.caption).foregroundStyle(.secondary)}
            if let code=store.identityCodes[project.id]?.records[draft.id]?.code{LabeledContent("Номер карточки",value:code).textSelection(.enabled)}
            TextField("Номер на месте · если есть",text:string(\.localNumber)).accessibilityIdentifier("cemetery-local-number")
            Picker("Участок / сектор",selection:string(\.parentEntityID)){
                Text("Не указан").tag("")
                ForEach(parents){p in Text(p.title+(p.localNumber.map{" · "+$0} ?? "")).tag(p.physicalID)}
            }.accessibilityIdentifier("cemetery-parent")
            if parents.isEmpty{Text("Сектор или участок можно создать через «Действия → Метки на плане».").font(.caption).foregroundStyle(.secondary)}
        }
        if draft.kind=="grave"{
            Section("Тип захоронения"){
                Picker("Тип",selection:string(\.burialKind,fallback:"unknown")){ForEach(BurialKind.allCases){Text($0.title).tag($0.rawValue)}}.accessibilityIdentifier("cemetery-burial-kind")
                Text("Одна могила или общий контур могут содержать много имён. Памятник сам по себе не подтверждает погребение каждого упомянутого человека здесь.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Число погребённых · если известно"){
                TextField("Не менее",value:$draft.totalMinimum,format:.number).keyboardType(.numberPad).accessibilityIdentifier("cemetery-total-min")
                TextField("Не более",value:$draft.totalMaximum,format:.number).keyboardType(.numberPad).accessibilityIdentifier("cemetery-total-max")
                TextField("Из них неустановленных",value:$draft.unidentifiedCount,format:.number).keyboardType(.numberPad)
                TextField("Источник оценки · надпись, документ…",text:string(\.countSource),axis:.vertical)
                Text("Если число неизвестно, оставьте поля пустыми. Для точного числа заполните обе границы одинаково. Количество имён на памятнике считается отдельно.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CemeteryPersonEditor:View {
    @Binding var person:PersonReading
    let remove:()->Void
    var body:some View{VStack(alignment:.leading,spacing:10){
        TextField("Имя как в источнике",text:$person.name)
        if let dates=person.datesText,!dates.isEmpty{Text("Даты в источнике: "+dates).font(.footnote).foregroundStyle(.secondary)}
        TextField("Рождение — если указано",text:$person.birth)
        TextField("Смерть — если указана",text:$person.death)
        Picker("Связь с местом",selection:Binding(get:{person.relation ?? "inscription"},set:{person.relation=$0})){ForEach(BurialRelation.allCases){Text($0.title).tag($0.rawValue)}}
        if let evidence=person.evidence,!evidence.isEmpty{Text("Исходных строк с фото: \(evidence.count)").font(.caption).foregroundStyle(.secondary)}
        Toggle("Чтение требует проверки",isOn:Binding(get:{person.needsReview ?? true},set:{person.needsReview=$0}))
        Button("Убрать эту запись имени",role:.destructive,action:remove)
    }.padding(.vertical,6)}
}
