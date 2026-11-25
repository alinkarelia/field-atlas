import SwiftUI
import FieldCore

struct WorkspaceView:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var missions:FieldMissionRecorder
    let project:FieldProject;let onBack:()->Void
    @StateObject private var location=LocationRecorder()
    @State private var editing:Observation?
    @State private var showTools=false
    @State private var showList=false
    @State private var showScan=false
    @State private var showTransfer=false
    @State private var showArchive=false
    @State private var trackKind:String?
    @State private var marker:String?
    @State private var showGeo=false
    @State private var notice:String?
    @State private var pendingPoint:Observation?
    @State private var confirmBoundary=false
    @State private var confirmDiscard=false
    @State private var centerRequest=UUID()
    @State private var showScanReview=false
    @State private var showAssistant=false
    @State private var showMissions=false
    private var records:[Observation]{store.records(project.id)}
    private var objects:[Observation]{records.filter{!["boundary","road","path"].contains($0.kind)}}
    var body:some View{
        ZStack(alignment:.top){
            if showGeo,let origin=store.state.origins[project.id]{MapLibrePlan(records:records,origin:origin).ignoresSafeArea(edges:.bottom)}
            else{LocalPlan(records:records,track:location.segments,currentPosition:location.freshPosition,centerRequest:centerRequest,onPick:selectPoint).ignoresSafeArea(edges:.bottom)}
            VStack{
                HStack(alignment:.top,spacing:12){Button(action:onBack){Image(systemName:"chevron.left").frame(width:48,height:48)}.accessibilityLabel("К проектам");VStack(alignment:.leading,spacing:4){Text(project.title).font(.headline);Text(project.type.title).font(.caption).foregroundStyle(.secondary)};Spacer();Button{showTransfer=true}label:{Image(systemName:"icloud.and.arrow.up").frame(width:48,height:48)}.accessibilityLabel("Передать")}.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(16)
                HStack{Spacer();VStack(spacing:10){Button{location.locate();centerRequest=UUID();notice=location.message}label:{Image(systemName:"location").frame(width:48,height:48).background(.white,in:RoundedRectangle(cornerRadius:12))}.accessibilityLabel("Моё положение");if store.state.origins[project.id] != nil{Button{showGeo.toggle()}label:{Image(systemName:showGeo ? "square.grid.3x3":"globe.europe.africa").frame(width:48,height:48).background(.white,in:RoundedRectangle(cornerRadius:12))}.accessibilityLabel("Переключить план")}}}.padding(.horizontal,16)
                Spacer()
                if missions.active{Button("● Записывается: "+(missions.selected?.title ?? "маршрут")){showMissions=true}.font(.footnote).padding(10).background(.white,in:Capsule())}
                if let notice{Text(notice).font(.footnote).padding(12).background(.white,in:RoundedRectangle(cornerRadius:12)).padding(.horizontal)}
                if let kind=trackKind{VStack(alignment:.leading,spacing:12){HStack{Text(kind=="boundary" ? "Граница" : kind=="road" ? "Дорога":"Тропинка").font(.headline);Spacer();Text("\(location.points.count) точек").font(.caption)};Text(location.message).font(.caption).foregroundStyle(.secondary);HStack{Button(location.paused ? "Продолжить":"Пауза"){location.pause()}.buttonStyle(.bordered);Button("Сохранить"){finishTrack()}.buttonStyle(.borderedProminent)};HStack{Button("Убрать точку"){location.undo()}.disabled(location.points.isEmpty);Button("Отменить обход",role:.destructive){confirmDiscard=true}.buttonStyle(.bordered)}}.padding(16).background(.white,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal)}
                HStack{Text("\(objects.count) объектов");Text("·");Button("Снятые участки: \(store.state.scans.filter{$0.projectId==project.id}.count)"){showScanReview=true}.accessibilityIdentifier("workspace-scans");Spacer()}.font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.bottom,8)
                HStack(spacing:0){dock(project.type.objectTitle,"plus"){createObject()}.accessibilityIdentifier("workspace-add");dock("Карта","point.topleft.down.curvedto.point.bottomright.up"){showGeo=false;showTools=true}.accessibilityIdentifier("workspace-tools");dock("Снять","viewfinder"){showScan=true}.accessibilityIdentifier("workspace-scan");dock("Задания","clock"){showMissions=true}.accessibilityIdentifier("workspace-missions");dock("Объекты","list.bullet"){showList=true}.accessibilityIdentifier("workspace-objects")}
                    .padding(6).background(Palette.green,in:RoundedRectangle(cornerRadius:20)).padding(.horizontal,16).padding(.bottom,12)
            }
        }.foregroundStyle(Palette.ink)
        .onAppear{if let saved=store.loadTrack(project.id){trackKind=saved.kind;location.restore(saved)};location.trackChanged={saveTrack()};location.origin=store.state.origins[project.id];location.originChanged={origin in do{try store.setOrigin(origin,projectId:project.id)}catch{notice=error.localizedDescription}}}
        .onDisappear{saveTrack();location.stop()}
        .alert("В границе есть разрывы GPS",isPresented:$confirmBoundary){
            Button("Сохранить с пометкой проверки"){finishTrack(acceptGap:true)}
            Button("Вернуться к обходу",role:.cancel){}
        }message:{Text("Приложение соединит концы прямыми линиями. Это предположение: граница останется отмеченной для проверки.")}
        .alert("Отменить текущий обход?",isPresented:$confirmDiscard){
            Button("Удалить незавершённый обход",role:.destructive){do{try store.clearTrack(project.id);location.stop();trackKind=nil;notice="Обход отменён"}catch{notice=error.localizedDescription}}
            Button("Продолжить",role:.cancel){}
        }message:{Text("Сохранённые границы, дороги и карточки останутся. Будет удалён только текущий незавершённый обход.")}
        .fullScreenCover(item:$editing){record in ObservationWizard(project:project,initial:record,onPick:{value in pendingPoint=value;editing=nil;showGeo=false;notice="Укажите место объекта на плане"})}
        .fullScreenCover(isPresented:$showList){NavigationStack{List(objects){record in Button{showList=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){editing=record}}label:{VStack(alignment:.leading,spacing:4){Text(record.title.isEmpty ? project.type.objectTitle:record.title);Text(record.status=="complete" ? "Собрано":"Черновик").font(.caption).foregroundStyle(.secondary)}}}.navigationTitle("Объекты проекта").toolbar{ToolbarItem(placement:.confirmationAction){Button("Готово"){showList=false}};if project.type == .cemetery{ToolbarItem(placement:.bottomBar){Button("Связи с архивом"){showList=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){showArchive=true}}}}}}}
        .fullScreenCover(isPresented:$showScanReview){ScanReviewScreen(project:project)}
        .sheet(isPresented:$showTransfer){TransferView(project:project)}
        .sheet(isPresented:$showAssistant){FieldAssistantView(project:project,context:"Тип работы: \(project.type.title). Карточек: \(records.count). Сохранённых секторов: \(store.state.scans.filter{$0.projectId==project.id}.count).")}
        .sheet(isPresented:$showMissions){FieldMissionsView(project:project)}
        .fullScreenCover(isPresented:$showArchive){NavigationStack{ArchiveLinksView(project:project).toolbar{Button("Готово"){showArchive=false}}}}
        .fullScreenCover(isPresented:$showScan){CapturePreparationScreen(project:project)}
        .confirmationDialog("Добавить на карту",isPresented:$showTools,titleVisibility:.visible){
            Button("Помощник x0"){showAssistant=true}
            Button("Полевые задания · маршрут и время"){showMissions=true}
            if project.type.outdoor{Button("Обойти границу"){beginTrack("boundary")};Button("Записать дорогу"){beginTrack("road")};Button("Записать тропинку"){beginTrack("path")};Button("Дерево"){marker="tree";notice="Укажите дерево на плане"};Button("Свалка"){marker="dump";notice="Укажите место на плане"}}
            Button("Препятствие"){marker="obstacle";notice="Укажите место препятствия"}
            if project.type == .cemetery{Button("Подозрительное углубление"){marker="anomaly";notice="Укажите место. Это отметка наблюдения, не подтверждение могилы."}}
        }
    }
    private func dock(_ title:String,_ symbol:String,action:@escaping()->Void)->some View{Button(action:action){VStack(spacing:6){Image(systemName:symbol).font(.title3);Text(title).font(.system(size:11,weight:.semibold))}.frame(maxWidth:.infinity,minHeight:56).contentShape(Rectangle()).foregroundStyle(.white)}.buttonStyle(.plain)}
    private func createObject(){var value=Observation(projectId:project.id,kind:project.type.objectKind);value.point=location.freshPosition;value.origin=location.origin;value.locationAccuracy=location.accuracy;value.locationMethod=location.freshPosition == nil ? nil:"gps";value.needsReview=location.accuracy.map{$0>5} ?? true;do{try store.save(value);editing=value}catch{notice=error.localizedDescription}}
    private func selectPoint(_ point:[Double]){
        if var value=pendingPoint{value.point=point;value.origin=store.state.origins[project.id];value.locationAccuracy=nil;value.locationMethod="manual";do{try store.save(value);editing=value;pendingPoint=nil;notice=nil}catch{notice=error.localizedDescription};return}
        if let marker{var value=Observation(projectId:project.id,kind:marker);value.point=point;value.origin=store.state.origins[project.id];value.locationAccuracy=nil;value.locationMethod="manual";value.title=["tree":"Дерево","dump":"Свалка","obstacle":"Препятствие","anomaly":"Углубление"][marker] ?? "Метка";do{try store.save(value);self.marker=nil;notice="Метка сохранена"}catch{notice=error.localizedDescription};return}
        let nearest=objects.filter{$0.point != nil}.min{hypot($0.point![0]-point[0],$0.point![1]-point[1])<hypot($1.point![0]-point[0],$1.point![1]-point[1])}
        if let nearest,let p=nearest.point,hypot(p[0]-point[0],p[1]-point[1])<3{editing=nearest}
    }
    private func saveTrack(){guard let kind=trackKind else{return};do{try store.saveTrack(TrackSnapshot(kind:kind,points:location.points,segments:location.segments,needsReview:location.needsReview),projectId:project.id)}catch{notice="Обход не сохранён: \(error.localizedDescription)";location.paused=true}}
    private func beginTrack(_ kind:String){if let saved=store.loadTrack(project.id){trackKind=saved.kind;location.restore(saved);notice="Продолжите ранее сохранённый обход";return};trackKind=kind;showGeo=false;location.begin();saveTrack()}
    private func finishTrack(acceptGap:Bool=false){
        guard let kind=trackKind else{return}
        if kind=="boundary" && !Geometry.validPolygon(location.points){notice="Контур пересекается или в нём мало точек. Уберите ошибочные последние точки или отмените обход.";return}
        if kind=="boundary" && location.needsReview && !acceptGap{confirmBoundary=true;return}
        guard location.points.count>=2 else{notice="Недостаточно точек";return}
        var value=Observation(projectId:project.id,kind:kind);value.points=location.points;value.segments=location.segments;value.origin=location.origin;value.needsReview=location.needsReview
        if value.needsReview{value.comments="В обходе есть разрывы GPS; соединения требуют проверки."}
        do{try store.save(value);try store.clearTrack(project.id);location.stop();trackKind=nil;notice="Геометрия сохранена"}catch{notice=error.localizedDescription}
    }
}


