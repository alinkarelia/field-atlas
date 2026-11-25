import SwiftUI
import FieldCore

struct ObservationWizard:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var sync:SyncClient
    @Environment(\.dismiss) var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var titleFocused:Bool
    let project:FieldProject
    let onPick:(Observation)->Void
    @State private var draft:Observation
    @State private var step=0
    @State private var photoRole:String?
    @State private var showCamera=false
    @State private var showMeasure=false
    @State private var showReading=false
    @State private var showAssistant=false
    @State private var showPlan=false
    @State private var machineText=""
    @State private var machineSourceHash=""
    @State private var notice=""
    @State private var saving=false
    @StateObject private var location=LocationRecorder()
    @State private var locating=false
    private let steps=["Место и название","Фотографии","Сведения","Размеры и заметки","Проверка"]
    init(project:FieldProject,initial:Observation,onPick:@escaping(Observation)->Void){self.project=project;self.onPick=onPick;_draft=State(initialValue:initial)}
    private var isGrave:Bool{draft.kind=="grave"}
    private var compactLayout:Bool{verticalSizeClass == .compact}
    var body:some View{
        NavigationStack{
            Form{
                if !compactLayout {Section{HStack(spacing:5){ForEach(0..<5){i in Capsule().fill(i<=step ? Palette.green:.gray.opacity(0.2)).frame(height:4)}};Text("\(project.type.objectTitle) · Шаг \(step+1) из 5").font(.caption).foregroundStyle(.secondary)}}
                if step==0{
                    Section{
                        TextField("Название или ориентир",text:$draft.title)
                            .accessibilityIdentifier("observation-title")
                            .focused($titleFocused).submitLabel(.done).onSubmit{titleFocused=false}
                        if draft.roomPlan != nil{Button("План помещения и размеры"){showPlan=true}}
                        if let p=draft.point{LabeledContent("Место в плане",value:String(format:"%.2f / %.2f м",p[0],p[1]))}
                        Button(locating ? "Остановить поиск GPS":"Определить место по GPS"){
                            if locating{locating=false;location.stop()}else{
                                location.origin=store.state.origins[project.id]
                                location.originChanged={origin in do{try store.setOrigin(origin,projectId:project.id)}catch{notice=error.localizedDescription;locating=false;location.stop()}}
                                locating=true;location.locate()
                            }
                        }.accessibilityIdentifier("observation-gps")
                        if locating{Text(location.message).font(.caption)}
                        if let accuracy=draft.locationAccuracy{Text("Погрешность GPS: ±\(Int(accuracy)) м. Проверьте место на плане.").font(.caption).foregroundStyle(.secondary)}
                        Button("Указать на плане"){if save(){onPick(draft)}}
                    }header:{if !compactLayout{Text("Объект")}}
                    if isGrave{Section{Text("Безымянное захоронение можно сохранить без имени. Номер объекта уже создан.").font(.footnote)}}
                }
                if step==1{Section("Снимки"){photoRow("Общий вид",role:"overview");photoRow(isGrave ? "Плита или табличка":"Деталь",role:isGrave ? "inscription":"detail");if isGrave{photoRow("Портрет на памятнике",role:"portrait");Toggle("Плиты или надписи нет",isOn:$draft.noInscription)}}}
                if step==2{
                    Section(isGrave ? "Текст с плиты":"Описание"){
                        TextEditor(text:$draft.transcription).frame(minHeight:140).accessibilityLabel(isGrave ? "Текст с плиты":"Описание")
                        if isGrave{Toggle("Нужно уточнить чтение",isOn:$draft.unreadable);Button("Распознать на устройстве"){Task{await readLocally()}};Button("Помощь x0"){guard save() else{return};showAssistant=true}.disabled(!draft.photos.contains(where:{$0.role=="inscription"}))}
                        Button("Спросить x0 по работе"){showAssistant=true}
                    }
                    if isGrave{Section("Люди, указанные на памятнике"){ForEach($draft.persons){$person in VStack(alignment:.leading,spacing:10){TextField("Имя",text:$person.name);TextField("Рождение — как на плите",text:$person.birth);TextField("Смерть — как на плите",text:$person.death);Button("Убрать человека из карточки",role:.destructive){draft.persons.removeAll{$0.id==person.id}}}.padding(.vertical,6)};Button("Добавить человека"){draft.persons.append(PersonReading())}}}
                }
                if step==3{
                    Section(isGrave ? "Участок по ограде":"Размеры"){
                        TextField("Длина, м",value:$draft.measureLength,format:.number).keyboardType(.decimalPad)
                        TextField("Ширина, м",value:$draft.measureWidth,format:.number).keyboardType(.decimalPad)
                        Picker("Способ",selection:$draft.measureMethod){Text("Не измерено").tag("none");Text("Рулетка").tag("tape");Text("AR-измерение").tag("ar");Text("Приблизительно").tag("estimate")}
                        Button("Измерить контур камерой"){showMeasure=true}
                        if let measured=draft.measuredArea{LabeledContent("Площадь контура",value:String(format:"%.2f м²",measured))}
                    }
                    Section("Комментарии"){TextEditor(text:$draft.comments).frame(minHeight:100).accessibilityLabel("Комментарии")}
                }
                if step==4{
                    Section("Собрано"){LabeledContent("Фотографии",value:String(draft.photos.count));LabeledContent("Место",value:draft.point==nil ? "Не указано":"На плане");if isGrave{LabeledContent("Люди",value:String(draft.persons.count))};if let area=draft.measuredArea ?? rectangleArea{LabeledContent("Площадь",value:String(format:"%.2f м²",area))}}
                    if !draft.missing.isEmpty{Section("Можно дополнить позже"){ForEach(draft.missing,id:\.self){Text($0).foregroundStyle(.orange)}}}
                    Section{Text("Машинное чтение остаётся предложением. Исходные снимки и неполные даты сохраняются.").font(.footnote)}
                }
                if !notice.isEmpty{Section{Text(notice).font(.footnote)}}
            }.scrollDismissesKeyboard(.interactively).navigationTitle(steps[step]).accessibilityIdentifier("observation-editor").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.cancellationAction){Button("Свернуть"){if save(){dismiss()}}}}
            .safeAreaInset(edge:.bottom){HStack{if step>0{Button("Назад"){if save(){step-=1}}.buttonStyle(.bordered)};Spacer();Button(step==4 ? "Сохранить":"Далее"){if step==4{draft.status=draft.missing.isEmpty ? "complete":"draft";if save(){dismiss()}}else if save(){step+=1}}.buttonStyle(.borderedProminent).accessibilityIdentifier("wizard-next")}.controlSize(.large).padding(.horizontal,16).padding(.vertical,compactLayout ? 8:16).background(.regularMaterial)}
        }
        .onChange(of:draft){_,_ in _=save()}
        .onChange(of:location.position){_,_ in
            if locating,let point=location.freshPosition{
                draft.point=point;draft.origin=location.origin;draft.locationAccuracy=location.accuracy;draft.locationMethod="gps"
                draft.needsReview=location.accuracy.map{$0>5} ?? true
                locating=false;location.stop();_=save()
            }
        }
        .onDisappear{location.stop();locating=false}
        .fullScreenCover(isPresented:$showPlan){if let doc=draft.roomPlan{NativeRoomPlanReview(document:doc,onLevelChange:{id,level in var next=draft;guard let i=next.roomPlan?.rooms.firstIndex(where:{$0.id==id}) else{return};next.roomPlan?.rooms[i].level=level;try store.save(next);draft=next},project:project,onCeilingChange:{id,value in try store.save(draft);let room=try store.attachCeiling(value,roomId:id,projectId:project.id);if let saved=store.records(project.id).first(where:{$0.id==draft.id}){draft=saved};return room})}}
        .fullScreenCover(isPresented:$showCamera){CameraPicker{image in showCamera=false;guard let image,let role=photoRole else{return};savePhoto(image,role:role)}}
        .fullScreenCover(isPresented:$showMeasure){CapturePreparationScreen(project:project,onMeasurement:{points,area,frame in draft.footprint=points;draft.measuredArea=area;draft.measurementFrameId=frame;draft.measureMethod="ar"})}
        .sheet(isPresented:$showReading){NavigationStack{ScrollView{VStack(alignment:.leading,spacing:18){Text(sync.message).foregroundStyle(.secondary);if !machineText.isEmpty{readingProposal(machineText,sourceHash:machineSourceHash)};if let job=sync.reading,job.recordId==draft.id{Text("Статус: \(job.state)").font(.caption);if let r=job.result,let source=r.originalSourceHash{readingProposal(r.text,sourceHash:source)};Button("Обновить результат"){Task{await sync.refreshReading()}}}}.padding(20)}.navigationTitle("Помощник чтения").toolbar{Button("Готово"){showReading=false}}}}
        .sheet(isPresented:$showAssistant){FieldAssistantView(project:project,context:"Работа с карточкой типа \(draft.kind).",photo:isGrave ? draft.photos.first(where:{$0.role=="inscription"}):nil,onReading:{text,hash in
            guard draft.photos.contains(where:{$0.role=="inscription" && $0.sha256==hash}) else{notice="Фото изменилось. Повторите чтение.";return}
            draft.transcription=text;draft.unreadable=true;draft.needsReview=true;_ = save()
        })}
    }
    private var rectangleArea:Double?{guard let l=draft.measureLength,let w=draft.measureWidth,l>0,w>0 else{return nil};return l*w}
    @discardableResult private func save()->Bool{
        if [draft.measureLength,draft.measureWidth].compactMap({$0}).contains(where:{!$0.isFinite || $0<=0 || $0>100000}){notice="Размер должен быть положительным числом в метрах.";return false}
        do{try store.save(draft);return true}catch{notice="Не удалось сохранить: \(error.localizedDescription)";return false}}
    private func photoRow(_ label:String,role:String)->some View{
        Button{photoRole=role;showCamera=true}label:{HStack(spacing:14){if let photo=draft.photos.first(where:{$0.role==role}),let file=store.assetURL(photo.id),let image=UIImage(contentsOfFile:file.path){Image(uiImage:image).resizable().scaledToFill().frame(width:64,height:64).clipShape(RoundedRectangle(cornerRadius:9))}else{Image(systemName:"camera").frame(width:64,height:64).background(Palette.paper,in:RoundedRectangle(cornerRadius:9))};VStack(alignment:.leading,spacing:5){Text(label);Text(draft.photos.contains(where:{$0.role==role}) ? "Сохранено · переснять":"Сделать фотографию").font(.caption).foregroundStyle(.secondary)};Spacer()}.padding(.vertical,6)}.buttonStyle(.plain)
    }
    private func savePhoto(_ image:UIImage,role:String){
        let renderer=UIGraphicsImageRenderer(size:image.size);let normalized=renderer.image{_ in image.draw(in:CGRect(origin:.zero,size:image.size))}
        guard let data=normalized.jpegData(compressionQuality:0.95) else{notice="Не удалось сохранить фотографию";return}
        do{let a=try store.saveAsset(data,projectId:project.id,mime:"image/jpeg",extension:"jpg");draft.photos.removeAll{$0.role==role};draft.photos.append(PhotoAttachment(id:a.id,role:role,sha256:a.sha256,name:a.filename));save()}catch{notice=error.localizedDescription}
    }
    private func readLocally()async{
        guard let photo=draft.photos.first(where:{$0.role=="inscription"}),let file=store.assetURL(photo.id),let image=UIImage(contentsOfFile:file.path)?.cgImage else{notice="Сначала снимите надпись";return}
        do{machineText=try await LocalOCR.read(image);machineSourceHash=photo.sha256;if machineText.isEmpty{notice="Текст не найден. Попробуйте другой свет или x0."}else{showReading=true}}catch{notice=error.localizedDescription}
    }
    private func readingProposal(_ text:String,sourceHash:String)->some View{VStack(alignment:.leading,spacing:12){Text("Предложение · требуется проверка").font(.caption).foregroundStyle(.orange);Text(text).textSelection(.enabled);Button("Вставить предложенный текст"){guard draft.photos.contains(where:{$0.role=="inscription" && $0.sha256==sourceHash}) else{notice="Фотография изменилась. Повторите чтение.";showReading=false;return};draft.transcription=text;draft.unreadable=true;save();showReading=false}.buttonStyle(.borderedProminent)}}
}
