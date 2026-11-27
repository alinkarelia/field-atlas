import SwiftUI
import FieldCore

struct WorkspaceView:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var maps:MapPackageStore
    @EnvironmentObject var missions:FieldMissionRecorder
    @Environment(\.scenePhase) private var phase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let project:FieldProject;let onBack:()->Void
    @StateObject private var location=LocationRecorder()
    @State private var editing:Observation?
    @State private var showTools=false
    @State private var showList=false
    @State private var showScan=false
    @State private var showTransfer=false
    @State private var showArchive=false
    @State private var trackKind:String?
    @State private var marker:SurveyFeature?
    @State private var markerGPS=false
    @State private var showGeo=true
    @StateObject private var territory=TerritoryStore()
    @State private var showTerritory=false
    @State private var showMaps=false
    @State private var showGPS=false
    @State private var mapFocus:GeoOrigin?
    @State private var mapFocusZoom:Double=10
    @State private var mapFocusBounds:[Double]?
    @State private var sitePlace:TerritoryPlace?
    @State private var selectedPlace:TerritoryPlace?
    @State private var geoScale="Карта округа"
    @State private var geoZoom=0
    @State private var geoFit=UUID()
    @State private var notice:String?
    @State private var pendingPoint:Observation?
    @State private var confirmBoundary=false
    @State private var confirmDiscard=false
    @State private var centerRequest=UUID()
    @State private var showScanReview=false
    @State private var showAssistant=false
    @State private var showMissions=false
    @State private var showTrackOptions=false
    @State private var requestedTrack="boundary"
    @State private var recordFilter="all"
    private var records:[Observation]{store.records(project.id)}
    private var objects:[Observation]{records.filter{!["boundary","road","path"].contains($0.kind)}}
    private var busyMap:Bool{trackKind != nil || marker != nil || pendingPoint != nil}
    private var hasBoundary:Bool{records.contains{$0.kind=="boundary"}}
    private var compact:Bool{verticalSizeClass == .compact}
    private func trackTitle(_ kind:String)->String{kind=="boundary" ? "Граница":kind=="road" ? "Дорога":"Тропинка"}
    var body:some View {
        ZStack(alignment:.top) {
            if showGeo && project.type.outdoor {MapLibrePlan(records:records,origin:store.state.origins[project.id],catalog:territory.catalog,mapURL:territory.mapURL,basemapStyleURL:maps.styleURL,geographicPosition:location.visiblePosition,accuracy:location.accuracy,focus:mapFocus,focusZoom:mapFocusZoom,focusBounds:mapFocusBounds,track:location.segments,currentPosition:location.freshPosition,centerRequest:centerRequest,zoomRequest:geoZoom,fitRequest:geoFit,selectedPlace:selectedPlace,placing:busyMap,onPick:selectGeographic,onSite:{sitePlace=$0},onRecord:{id in editing=objects.first{$0.id==id}},onScale:{if geoScale != $0{geoScale=$0}},onMapError:{maps.mapFailed()},onMapCenter:{maps.updateContext($0)}).ignoresSafeArea(edges:.bottom)}
            else{LocalPlan(records:records,track:location.segments,currentPosition:location.freshPosition,centerRequest:centerRequest,onPick:selectPoint).ignoresSafeArea(edges:.bottom)}
            VStack(spacing:8) {
                header
                if !compact{HStack{Spacer();Button{mapFocus=nil;mapFocusBounds=nil;maps.updateContext(location.visiblePosition);location.locate();centerRequest=UUID();if location.canOpenSettings{showGPS=true}}label:{Image(systemName:"location").frame(width:48,height:48).background(.regularMaterial,in:Circle())}.accessibilityLabel("Моё положение").accessibilityIdentifier("map-locate")}.padding(.horizontal,16)}
                if showGeo && project.type.outdoor {geoControls}
                Spacer(minLength:0)
                if missions.active{Button("● Записывается: "+(missions.selected?.title ?? "маршрут")){showMissions=true}.font(.footnote).padding(8).background(.regularMaterial,in:Capsule())}
                if let notice {HStack{Text(notice).font(.footnote);Spacer();Button{self.notice=nil}label:{Image(systemName:"xmark").frame(width:36,height:36)}.accessibilityLabel("Убрать уведомление")}.padding(.leading,12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding(.horizontal)}
                if let kind=trackKind{trackPanel(kind)}
                else if marker != nil || pendingPoint != nil{placementPanel}
                else{nextStepPanel}
                dockBar
            }
        }
        .onAppear{maps.load(root:store.root);territory.load(root:store.root);location.origin=store.state.origins[project.id];if let saved=store.loadTrack(project.id){trackKind=saved.kind;location.restore(saved);if saved.origin==nil && location.origin==nil && !saved.points.isEmpty{showGeo=false}};location.trackChanged={saveTrack()};location.originChanged={origin in do{try store.setOrigin(origin,projectId:project.id)}catch{notice=error.localizedDescription}};if project.type.outdoor{location.locate();maps.updateContext(location.visiblePosition ?? location.origin)}}
        .onDisappear{saveTrack();location.stop();location.stopLocation()}
        .onChange(of:phase){_,p in if p == .background{if trackKind != nil,!location.manual,!location.paused{location.pause();saveTrack()};location.stopLocation()}else if p == .active,project.type.outdoor{location.locate()}}
        .onChange(of:location.position){_,_ in if markerGPS,let p=location.freshPosition{saveMarker(p,gps:true)}}
        .alert("В границе есть разрывы GPS",isPresented:$confirmBoundary){Button("Сохранить с пометкой проверки"){finishTrack(acceptGap:true)};Button("Вернуться к обходу",role:.cancel){}}message:{Text("Концы разрывов соединятся прямыми. Проверьте эти участки; точность границы ограничена GPS.")}
        .alert("Отменить текущий обход?",isPresented:$confirmDiscard){Button("Удалить незавершённый обход",role:.destructive){do{try store.clearTrack(project.id);location.stop();location.points=[];location.segments=[];trackKind=nil;notice="Незавершённый обход удалён"}catch{notice=error.localizedDescription}};Button("Продолжить",role:.cancel){}}message:{Text("Сохранённые границы, дороги и карточки останутся.")}
        .fullScreenCover(item:$editing){record in ObservationWizard(project:project,initial:record,onPick:{value in pendingPoint=value;editing=nil;showGeo=project.type.outdoor;notice=nil})}
        .fullScreenCover(isPresented:$showList){recordsView}
        .fullScreenCover(isPresented:$showScanReview){ScanReviewScreen(project:project)}
        .sheet(isPresented:$showTransfer){TransferView(project:project)}
        .sheet(isPresented:$showAssistant){FieldAssistantView(project:project,context:"Тип работы: \(project.type.title). Границ: \(records.filter{$0.kind=="boundary"}.count). Захоронений: \(records.filter{$0.kind=="grave"}.count). Карточек: \(objects.count). Секторов: \(store.state.scans.filter{$0.projectId==project.id}.count).")}
        .sheet(isPresented:$showMissions){FieldMissionsView(project:project)}
        .fullScreenCover(isPresented:$showArchive){NavigationStack{ArchiveLinksView(project:project).toolbar{Button("Готово"){showArchive=false}}}}
        .fullScreenCover(isPresented:$showScan){CapturePreparationScreen(project:project)}
        .sheet(isPresented:$showMaps){MapLibraryView(onSelect:{maps.select($0);mapFocus=$0.center;mapFocusBounds=$0.bounds;mapFocusZoom=$0.area>10 ? 6:$0.area>1 ? 9:12;showGeo=true})}
        .sheet(isPresented:$showGPS){GPSStatusView(location:location)}
        .sheet(isPresented:$showTerritory){TerritoryView(territory:territory,onSelect:{selectedPlace=$0;showGeo=true})}
        .sheet(item:$sitePlace){place in TerritoryPlaceView(place:place,onLocate:{selectedPlace=place;showGeo=true})}
        .sheet(isPresented:$showTools){toolsView}
        .sheet(isPresented:$showTrackOptions){trackOptions}
    }
    private var geoControls:some View {
        HStack(alignment:.top){
            if !busyMap {VStack(alignment:.leading,spacing:4){Button{showTerritory=true}label:{Label("Карта и места",systemImage:"map").font(.subheadline).padding(12).background(.regularMaterial,in:Capsule())}.accessibilityIdentifier("workspace-territory")
                Button{showMaps=true}label:{Label(maps.activeMapName+(maps.offlineReady ? " · офлайн":" · сеть"),systemImage:"arrow.down.circle").font(.caption2).padding(8).background(.regularMaterial,in:Capsule())}.accessibilityIdentifier("workspace-map-downloads")
                Button{showGPS=true}label:{Text(location.message).font(.caption2).padding(8).background(.regularMaterial,in:Capsule())}.accessibilityIdentifier("workspace-gps-status")
                Text("© OpenStreetMap · ODbL").font(.system(size:10)).padding(4).background(.regularMaterial,in:Capsule())
            }}
            Spacer()
            VStack(spacing:4){Button{geoZoom+=1}label:{Image(systemName:"plus").frame(width:44,height:44)}.accessibilityLabel("Приблизить").accessibilityIdentifier("map-zoom-in");Button{geoZoom-=1}label:{Image(systemName:"minus").frame(width:44,height:44)}.accessibilityLabel("Отдалить").accessibilityIdentifier("map-zoom-out");Button{mapFocusBounds=nil;mapFocus=nil;geoFit=UUID()}label:{Image(systemName:"arrow.up.left.and.arrow.down.right").frame(width:44,height:44)}.accessibilityLabel("Показать весь план").accessibilityIdentifier("map-fit")}.background(.regularMaterial,in:Capsule())
        }.overlay(alignment:.bottomLeading){if !busyMap{Text(geoScale).font(.caption2).padding(6).background(.regularMaterial,in:Capsule()).offset(y:28).allowsHitTesting(false).accessibilityIdentifier("map-scale")}}.padding(.horizontal,16)
    }
    private func selectGeographic(_ coordinate:[Double]){
        guard TerritoryCatalog.validCoordinate(coordinate)else{return}
        if location.origin==nil {
            guard pendingPoint != nil || marker != nil || (trackKind != nil && location.manual) else{return}
            // A legacy local track has no geographic anchor and must stay local.
            guard location.points.isEmpty else{notice="У этого контура нет географической привязки. Продолжите его на локальном плане.";return}
            let origin=GeoOrigin(lat:coordinate[0],lon:coordinate[1])
            do{try store.setOrigin(origin,projectId:project.id);location.origin=origin}catch{notice=error.localizedDescription;return}
        }
        guard let origin=location.origin else{return}
        selectPoint(Geometry.local(lat:coordinate[0],lon:coordinate[1],origin:origin))
    }
    private var header:some View {
        HStack(spacing:8){Button(action:onBack){Image(systemName:"chevron.left").frame(width:44,height:44)}.accessibilityLabel("К проектам");VStack(alignment:.leading,spacing:3){Text(project.title).font(.headline).lineLimit(1);Text(project.type.title).font(.caption).foregroundStyle(.secondary)};Spacer(minLength:0);Button{showAssistant=true}label:{Text("x0").font(.system(size:20,weight:.bold,design:.rounded)).frame(width:48,height:48)}.accessibilityLabel("Помощник x0").accessibilityIdentifier("workspace-assistant");Button{showTransfer=true}label:{Image(systemName:"icloud.and.arrow.up").frame(width:44,height:44)}.accessibilityLabel("Передать")}.padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12).padding(.top,8)
    }
    private var nextStepPanel:some View {
        VStack(alignment:.leading,spacing:10){
            HStack{Text(project.type == .cemetery ? "Работа на кладбище":"План работы").font(.headline);Spacer();Button("Все действия"){showTools=true}.font(.subheadline).accessibilityIdentifier("workspace-guide")}
            if project.type.outdoor {
                HStack(spacing:6){quick("Граница","point.topleft.down.curvedto.point.bottomright.up","boundary");quick("Дорога","road.lanes","road");quick("Тропинка","figure.walk","path")}
                if project.type == .cemetery && !compact{Text(hasBoundary ? "Граница нанесена. Добавляйте захоронения и метки; снимайте сектора по мере обхода.":"Начните с обхода границы. Захоронения можно добавлять и до завершения карты.").font(.caption).foregroundStyle(.secondary)}
            } else{Text("«Снять» открывает камеру. После обмера комнаты проверьте её план, проёмы и размеры.").font(.subheadline).foregroundStyle(.secondary)}
            HStack{Text("Карточек: \(objects.count)");Spacer();Button("Секторы: \(store.state.scans.filter{$0.projectId==project.id}.count)"){showScanReview=true}.accessibilityIdentifier("workspace-scans")}.font(.caption)
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12)
    }
    private func quick(_ title:String,_ symbol:String,_ kind:String)->some View {
        Button{openTrack(kind)}label:{VStack(spacing:6){Image(systemName:symbol);Text(title).font(.caption.weight(.semibold))}.frame(maxWidth:.infinity,minHeight:52).background(Palette.green.opacity(0.09),in:RoundedRectangle(cornerRadius:10))}.buttonStyle(.plain).accessibilityIdentifier("workspace-"+kind)
    }
    private var dockBar:some View {
        HStack(spacing:0){dock(project.type == .cemetery ? "Захоронение":"Карточка","plus"){createObject()}.accessibilityLabel("Добавить: "+project.type.objectTitle).accessibilityIdentifier("workspace-add");dock("Метки","mappin.and.ellipse"){showTools=true}.accessibilityIdentifier("workspace-tools");dock("Снять","viewfinder"){showScan=true}.accessibilityIdentifier("workspace-scan");dock("Задания","clock"){showMissions=true}.accessibilityIdentifier("workspace-missions");dock("Список","list.bullet"){showList=true}.accessibilityIdentifier("workspace-objects")}.disabled(busyMap).padding(5).background(Palette.green,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12).padding(.bottom,8)
    }
    private func dock(_ title:String,_ symbol:String,action:@escaping()->Void)->some View {Button(action:action){VStack(spacing:5){Image(systemName:symbol).font(.title3);Text(title).font(.system(size:10,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.8)}.frame(maxWidth:.infinity,minHeight:54).contentShape(Rectangle()).foregroundStyle(.white)}.buttonStyle(.plain)}
    private func trackPanel(_ kind:String)->some View {
        VStack(alignment:.leading,spacing:10){
            HStack{Text(trackTitle(kind)+(location.manual ? " · по точкам":" · обход GPS")).font(.headline);Spacer();Text("\(location.points.count) точек").monospacedDigit().font(.caption).accessibilityIdentifier("track-count")}
            if !compact{Text(location.manual ? "Касайтесь плана: добавляйте углы по порядку. Двумя пальцами меняйте масштаб.":kind=="boundary" ? "Идите вдоль внешней границы и вернитесь к началу. Точки записываются автоматически.":"Идите по середине выбранной дороги или тропинки. В конце нажмите «Сохранить».").font(.caption)}
            if !location.manual{Text(location.message).font(.caption).foregroundStyle(.secondary)}
            HStack{if !location.manual{Button(location.paused ? "Продолжить":"Пауза"){location.pause()}.buttonStyle(.bordered).accessibilityIdentifier("track-pause")};Button("Убрать точку"){location.undo()}.disabled(location.points.isEmpty).accessibilityIdentifier("track-undo");Spacer();Button("Сохранить"){finishTrack()}.buttonStyle(.borderedProminent).disabled(location.points.count < (kind=="boundary" ? 3:2)).accessibilityIdentifier("track-save")}
            Button("Отменить \(location.manual ? "контур":"обход")",role:.destructive){confirmDiscard=true}.font(.caption).accessibilityIdentifier("track-discard")
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12)
    }
    private var placementPanel:some View {
        VStack(alignment:.leading,spacing:10){Text(pendingPoint != nil ? "Место захоронения / объекта":marker?.title ?? "Метка").font(.headline);Text("Коснитесь нужного места на плане. Масштаб можно изменить кнопками + и −.").font(.subheadline)
            HStack{if marker != nil{Button(markerGPS ? "Ожидаем GPS…":"Поставить здесь по GPS"){markerGPS=true;if let p=location.freshPosition{saveMarker(p,gps:true)}else{location.locate()}}.buttonStyle(.borderedProminent).disabled(markerGPS)};Spacer();Button("Отмена"){if let value=pendingPoint{pendingPoint=nil;editing=value};marker=nil;markerGPS=false;location.stop()}}
            if markerGPS{Text(location.message).font(.caption)}
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,12)
    }
    private var toolsView:some View {
        NavigationStack{List{
            if project.type.outdoor{Section("1 · Территория и пути"){
                SurveyAction(title:"Обойти границу",detail:"Замкнутый полигон кладбища или участка",symbol:"point.topleft.down.curvedto.point.bottomright.up"){openTrack("boundary")}
                SurveyAction(title:"Записать дорогу",detail:"Пройти по дороге с записью GPS",symbol:"road.lanes"){openTrack("road")}
                SurveyAction(title:"Записать тропинку",detail:"Отдельная линия пешеходного прохода",symbol:"figure.walk"){openTrack("path")}
            }}
            Section(project.type == .cemetery ? "2 · Захоронения":"Карточки"){
                SurveyAction(title:project.type == .cemetery ? "Создать карточку захоронения":"Создать карточку",detail:"Место → фото → надпись и люди → размеры → проверка",symbol:"plus.rectangle.on.rectangle"){afterTools{createObject()}}
            }
            Section("Метки на плане"){
                ForEach(SurveyFeature.allCases.filter{project.type == .cemetery || ![.anomaly,.sector,.plot].contains($0)}){feature in
                    SurveyAction(title:feature.title,detail:feature == .anomaly ? "Наблюдение, требующее проверки":"Указать на плане или по текущему GPS",symbol:feature.symbol){showTools=false;showGeo=project.type.outdoor;marker=feature;notice=nil}.accessibilityIdentifier("marker-"+feature.rawValue)
                }
            }
            Section("Съёмка и помощь"){
                SurveyAction(title:"Снимать LiDAR",detail:"Полный экран камеры, сохранение частями",symbol:"viewfinder"){afterTools{showScan=true}}
                SurveyAction(title:"Помощник x0",detail:"Подсказки по работе; чтение надписи — из её фотографии в карточке",symbol:"sparkles"){afterTools{showAssistant=true}}
                SurveyAction(title:"Полевые задания",detail:"Маршрут пешком или на машине, время и скорость",symbol:"clock"){afterTools{showMissions=true}}
                Button("Снятые сектора и привязка"){afterTools{showScanReview=true}}
                if project.type.outdoor{Button(showGeo ? "Показать рабочий план":"Показать географический обзор"){showGeo.toggle();showTools=false;if showGeo{let local=records.filter{$0.origin==nil && ($0.point != nil || !$0.points.isEmpty)}.count;notice=local>0 ? "Без географической привязки: \(local). Эти объекты остаются на рабочем плане.":nil}}}
            }
        }.navigationTitle(project.type == .cemetery ? "Работа на кладбище":"Действия проекта").navigationBarTitleDisplayMode(.inline).toolbar{Button("К карте"){showTools=false}}}
    }
    private var trackOptions:some View {
        NavigationStack{List{
            Section(trackTitle(requestedTrack)) {Text(requestedTrack=="boundary" ? "Подойдите к границе, начните запись и обойдите территорию по периметру. В конце сохраните: последняя точка соединится с первой.":"Начните у начала пути и пройдите до его конца. Дорога и тропинка сохраняются отдельными линиями внутри проекта.")}
            Section {
                SurveyAction(title:"Начать обход по GPS",detail:"Потребуется разрешение на геолокацию. Погрешность будет показана во время записи.",symbol:"location.fill"){showTrackOptions=false;beginTrack(requestedTrack)}.accessibilityIdentifier("track-start-gps")
                SurveyAction(title:"Нарисовать точками на плане",detail:"Для уточнения схемы вручную. Это приблизительный контур, требующий проверки.",symbol:"hand.draw"){showTrackOptions=false;beginTrack(requestedTrack,manual:true)}.accessibilityIdentifier("track-start-manual")
            }
        }.navigationTitle(trackTitle(requestedTrack)).toolbar{Button("Отмена"){showTrackOptions=false}}}
    }
    private var recordsView:some View {
        NavigationStack{List{
            Picker("Показывать",selection:$recordFilter){Text("Всё").tag("all");Text("Карточки").tag("cards");Text("Пути").tag("tracks")}.pickerStyle(.segmented)
            ForEach(records.filter{recordFilter=="all" || (recordFilter=="tracks") == ["boundary","road","path"].contains($0.kind)}){record in
                if ["boundary","road","path"].contains(record.kind){VStack(alignment:.leading,spacing:5){Text(record.title.isEmpty ? trackTitle(record.kind):record.title).font(.headline);Text("\(record.points.count) точек"+(record.kind=="boundary" ? String(format:" · %.0f м²",Geometry.area(record.points)):"")+(record.needsReview ? " · требует проверки":"")).font(.caption).foregroundStyle(.secondary)}}
                else{Button{showList=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){editing=record}}label:{HStack{Image(systemName:SurveyFeature(rawValue:record.kind)?.symbol ?? "rectangle.stack");VStack(alignment:.leading,spacing:4){Text(record.title.isEmpty ? project.type.objectTitle+" · "+record.id.prefix(6):record.title);Text("\(record.photos.count) фото · "+(record.status=="complete" ? "Собрано":"Черновик")).font(.caption).foregroundStyle(.secondary)}}}}
            }
            if records.isEmpty{Text("Пока нет объектов. Создайте карточку или начните обход на карте.")}
        }.navigationTitle("Объекты проекта").toolbar{ToolbarItem(placement:.confirmationAction){Button("Готово"){showList=false}};if project.type == .cemetery{ToolbarItem(placement:.bottomBar){Button("Связи с архивом"){showList=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){showArchive=true}}}}}}
    }
    private func afterTools(_ action:@escaping()->Void){showTools=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:action)}
    private func openTrack(_ kind:String){requestedTrack=kind;if showTools{afterTools{showTrackOptions=true}}else{showTrackOptions=true}}
    private func createObject(){var value=Observation(projectId:project.id,kind:project.type.objectKind);value.point=location.freshPosition;value.origin=location.origin;value.locationAccuracy=location.accuracy;value.locationMethod=location.freshPosition == nil ? nil:"gps";value.needsReview=location.accuracy.map{$0>5} ?? true;do{try store.save(value);editing=value}catch{notice=error.localizedDescription}}
    private func selectPoint(_ point:[Double]){
        if trackKind != nil{if location.manual{location.addManual(point)};return}
        if var value=pendingPoint{value.point=point;value.origin=store.state.origins[project.id];value.locationAccuracy=nil;value.locationMethod="manual";value.needsReview=true;do{try store.save(value);editing=value;pendingPoint=nil;notice=nil}catch{notice=error.localizedDescription};return}
        if marker != nil{saveMarker(point,gps:false);return}
        let nearest=objects.filter{$0.point != nil}.min{hypot($0.point![0]-point[0],$0.point![1]-point[1])<hypot($1.point![0]-point[0],$1.point![1]-point[1])}
        if let nearest,let p=nearest.point,hypot(p[0]-point[0],p[1]-point[1])<3{editing=nearest}
    }
    private func saveMarker(_ point:[Double],gps:Bool){guard let marker else{return};var value=Observation(projectId:project.id,kind:marker.rawValue);value.point=point;value.origin=store.state.origins[project.id];value.locationAccuracy=gps ? location.accuracy:nil;value.locationMethod=gps ? "gps":"manual";value.needsReview=true;value.title=marker.title;if marker == .anomaly{value.comments="Наблюдаемое углубление. Наличие захоронения не подтверждено."};do{try store.save(value);self.marker=nil;markerGPS=false;location.stop();editing=value;notice=nil}catch{notice=error.localizedDescription}}
    private func saveTrack(){guard let kind=trackKind else{return};do{try store.saveTrack(TrackSnapshot(kind:kind,points:location.points,segments:location.segments,needsReview:location.needsReview,manual:location.manual,origin:location.origin),projectId:project.id)}catch{notice="Обход не сохранён: \(error.localizedDescription)";location.paused=true}}
    private func beginTrack(_ kind:String,manual:Bool=false){if let saved=store.loadTrack(project.id){trackKind=saved.kind;location.restore(saved);notice="Продолжите ранее сохранённый обход";return};trackKind=kind;notice=nil;location.begin(manual:manual);saveTrack()}
    private func finishTrack(acceptGap:Bool=false){
        guard let kind=trackKind else{return}
        if kind=="boundary" && !Geometry.validPolygon(location.points){notice="Контур пересекается или в нём мало точек. Уберите ошибочные последние точки.";return}
        if kind=="boundary" && location.needsReview && !location.manual && !acceptGap{confirmBoundary=true;return}
        guard location.points.count>=2 else{notice="Недостаточно точек";return}
        var value=Observation(projectId:project.id,kind:kind);value.title=trackTitle(kind)+" \(records.filter{$0.kind==kind}.count+1)";value.points=location.points;value.segments=location.segments;value.origin=location.origin;value.needsReview=location.needsReview;value.locationMethod=location.manual ? "manual":"gps";value.status="complete"
        if value.needsReview{value.comments=location.manual ? "Ручной контур на плане; положение и размеры требуют проверки.":"В обходе есть разрывы GPS; соединения требуют проверки."}
        do{try store.save(value);try store.clearTrack(project.id);location.stop();location.points=[];location.segments=[];trackKind=nil;notice=value.title+" сохранена. Можно добавлять карточки, пути и метки."}catch{notice=error.localizedDescription}
    }
}
