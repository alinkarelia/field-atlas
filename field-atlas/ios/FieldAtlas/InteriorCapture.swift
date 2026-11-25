import SwiftUI
import RoomPlan
import ARKit
import FieldCore

@MainActor final class InteriorCaptureController:NSObject,ObservableObject,RoomCaptureViewDelegate,RoomCaptureSessionDelegate {
    let view=RoomCaptureView(frame:.zero)
    let surfaceView=RoomSurfaceView(frame:.zero)
    @Published var liveWalls=0
    @Published var liveOpenings=0
    @Published var scanning=false
    @Published var processing=false
    @Published var message="Осмотрите стены, окна и дверные проёмы"
    @Published var latest:RoomPlanDocument?
    @Published var savedCount=0
    @Published var error:String?
    private var store:AppStore?
    private var project:FieldProject?
    var selectedLevel=1
    private var processingLevel=1
    private var roomLevels:[UUID:Int]=[:]
    private var frameId=UUID().uuidString
    private var newGroupOnResume=false
    private var captured:[CapturedRoom]=[]
    private var unsaved:CapturedRoom?
    var hasUnsaved:Bool{unsaved != nil}
    var supported:Bool{RoomCaptureSession.isSupported}
    override init(){super.init();view.delegate=self;view.captureSession.delegate=self;view.isModelEnabled=true}
    required init?(coder:NSCoder){super.init();view.delegate=self;view.captureSession.delegate=self;view.isModelEnabled=true}
    func encode(with coder:NSCoder){}
    func configure(store:AppStore,project:FieldProject){self.store=store;self.project=project;startRoom()}
    func startRoom(){guard supported,!processing,unsaved==nil else{return};if let root=store?.root,let reason=DeviceReadiness.stopReason(free:DeviceReadiness.freeSpace(root),thermal:ProcessInfo.processInfo.thermalState){message=reason;return};if newGroupOnResume{frameId=UUID().uuidString;captured=[];savedCount=0;latest=nil;newGroupOnResume=false};surfaceView.surfaces.reset();liveWalls=0;liveOpenings=0;var config=RoomCaptureSession.Configuration();config.isCoachingEnabled=true;view.captureSession.run(configuration:config);scanning=true;message="Снимите все стены, затем окна и проходы. Следуйте подсказкам камеры."}
    nonisolated func captureSession(_ session:RoomCaptureSession,didUpdate room:CapturedRoom){Task{@MainActor [weak self] in self?.showProgress(room)}}
    private func showProgress(_ room:CapturedRoom){
        guard scanning else{return};liveWalls=room.walls.count;liveOpenings=room.doors.count+room.windows.count+room.openings.count
        surfaceView.surfaces.showRoom(room)
        message=liveWalls==0 ? "Медленно наведите камеру на стену с расстояния 1–3 м":"Зелёная штриховка — стена распознана. Оранжевая — осмотрите ещё."
    }
    nonisolated func captureSession(_ session:RoomCaptureSession,didProvide instruction:RoomCaptureSession.Instruction){
        Task{@MainActor [weak self] in
            guard let self,self.scanning else{return}
            switch instruction{
            case .moveCloseToWall:self.message="Подойдите ближе к стене"
            case .moveAwayFromWall:self.message="Отойдите немного от стены"
            case .slowDown:self.message="Двигайте камеру медленнее"
            case .turnOnLight:self.message="Добавьте освещение"
            case .normal:break
            @unknown default:break
            }
        }
    }
    nonisolated func captureSession(_ session:RoomCaptureSession,didEndWith data:CapturedRoomData,error:Error?){
        if let error{Task{@MainActor [weak self] in self?.scanning=false;self?.processing=false;self?.error="Съёмка остановлена: \(error.localizedDescription). Сохранённые комнаты доступны."}}
    }
    func finishRoom(){guard scanning else{return};processingLevel=selectedLevel;scanning=false;processing=true;message="Строим план и сохраняем исходные измерения…";view.captureSession.stop(pauseARSession:false)}
    func pause(){if scanning{finishRoom()};view.captureSession.arSession.pause();newGroupOnResume=true}
    nonisolated func captureView(shouldPresent roomDataForProcessing:CapturedRoomData,error:Error?)->Bool{
        if let error{Task{@MainActor [weak self] in self?.processing=false;self?.error=error.localizedDescription};return false};return true
    }
    nonisolated func captureView(didPresent processedResult:CapturedRoom,error:Error?){
        Task{@MainActor [weak self] in guard let self else{return};self.processing=false;if let error{self.error=error.localizedDescription;return};self.unsaved=processedResult;self.persistResult()}
    }
    func persistResult(){
        guard let room=unsaved,let store,let project else{return}
        do{
            let source=try store.saveAsset(store.encoder.encode(room),projectId:project.id,mime:"application/json",extension:"json")
            let normalized=Self.normalize(room,name:"Комната \(captured.count+1)",levelOverride:processingLevel)
            guard !normalized.walls.isEmpty else{unsaved=nil;self.error="Стены не распознаны. Исходник сохранён; начните съёмку комнаты заново.";return}
            let doc=RoomPlanDocument(frameId:frameId,rooms:[normalized])
            let plan=try store.saveAsset(store.encoder.encode(doc),projectId:project.id,mime:"application/json",extension:"json")
            var record=Observation(projectId:project.id,kind:"room");record.id=room.identifier.uuidString;record.title=normalized.name;record.roomPlan=doc;record.roomPlanSourceId=source.id;record.roomPlanAssetId=plan.id
            record.comments="RoomPlan: проверьте проёмы и контрольные размеры. Потолок отдельно не измерен."
            try store.save(record);roomLevels[room.identifier]=processingLevel;captured.append(room);savedCount=captured.count;latest=doc;unsaved=nil
            message="Комната сохранена. Можно проверить размеры или перейти в соседнюю комнату."
        }catch{self.error="Не удалось сохранить комнату. Повторите сохранение до закрытия: \(error.localizedDescription)"}
    }
    func exportStructure()async{
        guard !captured.isEmpty,!scanning,!processing,unsaved==nil,let store,let project else{return};processing=true;defer{processing=false}
        do{
            let builder=StructureBuilder(options:[.beautifyObjects]);let structure=try await builder.capturedStructure(from:captured)
            let raw=try store.saveAsset(store.encoder.encode(structure),projectId:project.id,mime:"application/json",extension:"json")
            let rooms=structure.rooms.enumerated().map{entry -> MeasuredRoom in
                var room=Self.normalize(entry.element,name:"Комната \(entry.offset+1)",levelOverride:roomLevels[entry.element.identifier])
                if let old=store.records(project.id).compactMap({$0.roomPlan?.rooms.first(where:{$0.id==room.id})}).first{
                    room.ceiling=old.ceiling;room.ceilingHeight=old.ceilingHeight;room.ceilingSource=old.ceilingSource;room.ceilingSourceId=old.ceilingSourceId;room.ceilingSourceHistory=old.ceilingSourceHistory
                };return room
            }
            let doc=RoomPlanDocument(frameId:frameId+"-structure-"+structure.identifier.uuidString,rooms:rooms)
            let plan=try store.saveAsset(store.encoder.encode(doc),projectId:project.id,mime:"application/json",extension:"json")
            let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".usdz")
            defer{try? FileManager.default.removeItem(at:file)}
            try structure.export(to:file,exportOptions:.parametric)
            let model=try store.saveAsset(Data(contentsOf:file),projectId:project.id,mime:"application/octet-stream",extension:"usdz")
            let records=doc.rooms.map{room -> Observation in
                var record=store.records(project.id).first(where:{$0.id==room.id}) ?? Observation(projectId:project.id,kind:"room")
                record.id=room.id;if record.title.isEmpty{record.title=room.name}
                record.roomPlan=RoomPlanDocument(frameId:doc.frameId,rooms:[room]);record.roomPlanAssetId=plan.id;record.roomPlanStructureId=raw.id;record.roomPlanModelId=model.id;return record
            }
            try store.saveAll(records)
            latest=doc;message="План \(captured.count) комнат и USDZ сохранены. Исходник: \(raw.id.prefix(8))."
        }catch{self.error="Объединение не подтверждено. Отдельные комнаты сохранены. \(error.localizedDescription)"}
    }
    func changeCeiling(_ id:String,_ value:CeilingMeasurement)throws->MeasuredRoom{
        guard let store,let project else{throw CocoaError(.validationMissingMandatoryProperty)}
        let room=try store.attachCeiling(value,roomId:id,projectId:project.id)
        if let index=latest?.rooms.firstIndex(where:{$0.id==id}){latest?.rooms[index]=room};return room
    }
    func changeLevel(_ id:String,_ level:Int)throws{
        guard let store,let project,var doc=latest,let index=doc.rooms.firstIndex(where:{$0.id==id}) else{return}
        let records=store.records(project.id).filter{$0.roomPlan?.rooms.contains(where:{$0.id==id}) == true}.map{record -> Observation in
            var copy=record;if let i=copy.roomPlan?.rooms.firstIndex(where:{$0.id==id}){copy.roomPlan?.rooms[i].level=level};return copy
        }
        try store.saveAll(records);doc.rooms[index].level=level;latest=doc;if let uuid=UUID(uuidString:id){roomLevels[uuid]=level}
    }
    static func normalize(_ room:CapturedRoom,name:String,levelOverride:Int?=nil)->MeasuredRoom{
        func confidence(_ s:CapturedRoom.Surface)->Int{switch s.confidence{case .high:return 2;case .medium:return 1;case .low:return 0;@unknown default:return 0}}
        func point(_ s:CapturedRoom.Surface,_ x:Float,_ y:Float)->SIMD4<Float>{s.transform*SIMD4<Float>(x,y,0,1)}
        var notes:[String]=[]
        let walls=room.walls.enumerated().map{index,s -> PlanWall in
            let a=point(s,-s.dimensions.x/2,0),b=point(s,s.dimensions.x/2,0),base=Double(s.transform.columns.3.y-s.dimensions.y/2)
            let profile=s.polygonCorners.count>=3 ? s.polygonCorners.map{[Double($0.x+s.dimensions.x/2),Double($0.y+s.dimensions.y/2)]}:nil
            return PlanWall(id:s.identifier.uuidString,code:"С\(index+1)",start:[Double(a.x),Double(a.z)],end:[Double(b.x),Double(b.z)],height:Double(s.dimensions.y),base:base,confidence:confidence(s),curved:s.curve != nil,profile:profile)
        }.filter{$0.length>0.05 && $0.height>0}
        var openings:[PlanOpening]=[]
        for (kind,surfaces,prefix) in [("door",room.doors,"Д"),("window",room.windows,"О"),("opening",room.openings,"П")]{
            for (index,s) in surfaces.enumerated(){
                guard let parent=s.parentIdentifier?.uuidString,let wall=walls.first(where:{$0.id==parent}),!wall.curved else{notes.append("\(prefix)\(index+1): привязка к стене требует проверки; проём сохранён в исходнике.");continue}
                let a=point(s,-s.dimensions.x/2,0),b=point(s,s.dimensions.x/2,0),dx=(wall.end[0]-wall.start[0])/wall.length,dy=(wall.end[1]-wall.start[1])/wall.length
                func position(_ p:SIMD4<Float>)->Double{(Double(p.x)-wall.start[0])*dx+(Double(p.z)-wall.start[1])*dy}
                let offset=min(position(a),position(b)),width=abs(position(a)-position(b)),height=Double(s.dimensions.y),sill=Double(s.transform.columns.3.y-s.dimensions.y/2)-wall.base
                guard offset >= -0.03,width>0,offset+width<=wall.length+0.05,sill >= -0.03,sill+height<=wall.height+0.10 else{notes.append("\(prefix)\(index+1): размеры выходят за стену — нужна проверка исходника.");continue}
                openings.append(PlanOpening(id:s.identifier.uuidString,code:"\(prefix)\(index+1)",kind:kind,wallId:parent,offset:offset,width:width,height:height,sill:sill))
            }
        }
        let floor=room.floors.first.flatMap{s -> [[Double]]? in guard s.polygonCorners.count>=3 else{return nil};return s.polygonCorners.map{p in let w=s.transform*SIMD4<Float>(p.x,p.y,p.z,1);return [Double(w.x),Double(w.z)]}}
        if room.floors.count>1{notes.append("Несколько поверхностей пола: показана первая, все поверхности сохранены в исходнике.")}
        return MeasuredRoom(id:room.identifier.uuidString,name:name,level:levelOverride ?? room.story,walls:walls,openings:openings,floor:floor,notes:notes)
    }
}

struct InteriorCaptureCamera:UIViewRepresentable {
    @ObservedObject var controller:InteriorCaptureController
    func makeUIView(context:Context)->RoomCaptureView{controller.view}
    func updateUIView(_ view:RoomCaptureView,context:Context){}
}
struct InteriorCaptureScreen:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var health:DeviceReadiness
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var phase
    let project:FieldProject
    @StateObject private var controller=InteriorCaptureController()
    @State private var review=false
    @State private var editFloor=false
    @State private var floorChoice=1
    @StateObject private var floorAdvisor=FloorAdvisor()
    var body:some View{
        ZStack(alignment:.bottom){
            if controller.supported{InteriorCaptureCamera(controller:controller).ignoresSafeArea();RoomSurfaceCamera(controller:controller).ignoresSafeArea().allowsHitTesting(false)}
            else{ContentUnavailableView("Съёмка помещения недоступна",systemImage:"viewfinder",description:Text("Нужен совместимый iPhone/iPad с LiDAR."))}
            VStack(spacing:8){
                if controller.scanning{Text("Стены: \(controller.liveWalls) · Проёмы: \(controller.liveOpenings)").font(.caption.monospacedDigit()).accessibilityIdentifier("room-live-progress")}
                HStack{Button("Этаж \(floorAdvisor.estimate.level) · изменить"){floorChoice=floorAdvisor.estimate.level;editFloor=true};Spacer();if let proposed=floorAdvisor.estimate.proposal{Button("Возможно, этаж \(proposed)"){floorChoice=proposed;editFloor=true}.tint(.orange)}}.font(.caption)
                Text(controller.message).font(.callout).frame(maxWidth:.infinity,alignment:.leading)
                if controller.processing{ProgressView("Обработка комнаты")}
                if controller.scanning{Button("Завершить комнату"){controller.finishRoom()}.buttonStyle(.borderedProminent)}
                else if !controller.processing{
                    if controller.latest == nil && !controller.hasUnsaved && controller.supported{Button("Начать комнату заново"){controller.startRoom()}.buttonStyle(.bordered)}
                    if controller.latest != nil{HStack{Button("План и размеры"){review=true};Button("Следующая комната"){controller.startRoom()}}.buttonStyle(.bordered);Button("Собрать план квартиры / дома"){Task{await controller.exportStructure()}}.buttonStyle(.bordered)}
                    if controller.hasUnsaved{Button("Повторить сохранение"){controller.persistResult()}}
                    Button("Готово"){controller.pause();dismiss()}.buttonStyle(.borderedProminent).disabled(controller.hasUnsaved)
                }
                if !controller.scanning{Text("Размеры привязаны к стенам и проёмам. Потолок измеряется отдельно.").font(.caption).foregroundStyle(.secondary)}
            }.padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)).padding(12)
        }.onAppear{controller.configure(store:store,project:project)}.onDisappear{controller.pause();floorAdvisor.stop()}
        .onChange(of:phase){_,value in if value != .active{controller.pause();floorAdvisor.stop()}}
        .onChange(of:health.stopReason){_,reason in if let reason,controller.scanning{controller.finishRoom();controller.message=reason}}
        .fullScreenCover(isPresented:$review){if let doc=controller.latest{NativeRoomPlanReview(document:doc,onLevelChange:controller.changeLevel,project:project,onCeilingStart:controller.pause,onCeilingChange:controller.changeCeiling)}}
        .sheet(isPresented:$editFloor){NavigationStack{Form{
            Section("Этаж текущей / следующей комнаты"){Stepper("Этаж \(floorChoice)",value:$floorChoice,in:-20...200);Text("Можно указать отрицательный уровень или 0 для цоколя. Сохранённые комнаты редактируются в их плане.").font(.footnote)}
            Section("Подсказка по высоте"){Text(floorAdvisor.message);Text("Изменение давления — только подсказка. Перепад высоты не определяет этаж точно.").font(.footnote);Button(floorAdvisor.active ? "Выключить подсказки":"Включить подсказки барометра"){if floorAdvisor.active{floorAdvisor.stop()}else{floorAdvisor.start()}}}
        }.navigationTitle("Выбор этажа").toolbar{ToolbarItem(placement:.cancellationAction){Button("Отмена"){editFloor=false}};ToolbarItem(placement:.confirmationAction){Button("Подтвердить"){floorAdvisor.confirm(floorChoice);controller.selectedLevel=floorChoice;editFloor=false}}}}}
        .alert("Проверка помещения",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){Button("Повторить сохранение"){controller.persistResult()};Button("Понятно"){controller.error=nil}}message:{Text(controller.error ?? "")}
    }
}
