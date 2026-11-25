import SwiftUI
import RoomPlan
import ARKit
import SceneKit
import AVFoundation
import CoreImage
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
    @Published var coverageVisible=true
    @Published var torchOn=false
    @Published var measureStart:SIMD3<Float>?
    @Published var toolMessage="Наведите центр экрана на поверхность для замера"
    private let measurementNode=SCNNode()
    private var measureNumber=0
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
    func configure(store:AppStore,project:FieldProject){self.store=store;self.project=project;surfaceView.scene?.rootNode.addChildNode(measurementNode);startRoom()}
    func toggleCoverage(){coverageVisible.toggle();surfaceView.surfaces.root.isHidden = !coverageVisible}
    func toggleTorch(){
        guard let device=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back),device.hasTorch,device.isTorchAvailable else{toolMessage="Фонарь недоступен на этом устройстве";return}
        do{try device.lockForConfiguration();defer{device.unlockForConfiguration()};if torchOn{device.torchMode = .off}else{try device.setTorchModeOn(level:0.5)};torchOn.toggle()}catch{self.error=error.localizedDescription}
    }
    func stopTorch(){if torchOn{toggleTorch()}}
    func addNote(_ text:String){
        guard let store,let project,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        do{var record=Observation(projectId:project.id,kind:"object");record.title="Заметка помещения";record.comments=String(text.prefix(4000));record.measurementFrameId=frameId;try store.save(record);toolMessage="Заметка сохранена в объектах проекта"}catch{self.error=error.localizedDescription}
    }
    func takePhoto(){
        guard scanning,let frame=view.captureSession.arSession.currentFrame,let store,let project else{return}
        let orientation=view.window?.windowScene?.interfaceOrientation ?? .portrait
        let image=CIImage(cvPixelBuffer:frame.capturedImage).oriented(orientation == .portrait ? .right:orientation == .portraitUpsideDown ? .left:orientation == .landscapeLeft ? .down:.up)
        do{guard let color=CGColorSpace(name:CGColorSpace.sRGB),let jpeg=CIContext().jpegRepresentation(of:image,colorSpace:color,options:[:]) else{throw CocoaError(.fileWriteUnknown)}
            let asset=try store.saveAsset(jpeg,projectId:project.id,mime:"image/jpeg",extension:"jpg")
            var record=Observation(projectId:project.id,kind:"object");record.title="Фото помещения";record.measurementFrameId=frameId
            record.photos=[PhotoAttachment(id:asset.id,role:"overview",sha256:asset.sha256,name:"Снимок во время обмера")]
            try store.save(record);toolMessage="Фотография сохранена в объектах проекта"
        }catch{self.error=error.localizedDescription}
    }
    func clearMeasure(){measureStart=nil;toolMessage="Первая точка отменена"}
    func measurePoint(){
        guard scanning,let frame=view.captureSession.arSession.currentFrame else{return}
        guard case .normal = frame.camera.trackingState else{toolMessage="Дождитесь устойчивого отслеживания камеры";return}
        let t=frame.camera.transform,origin=SIMD3<Float>(t.columns.3.x,t.columns.3.y,t.columns.3.z),direction = -SIMD3<Float>(t.columns.2.x,t.columns.2.y,t.columns.2.z)
        let query=ARRaycastQuery(origin:origin,direction:direction,allowing:.estimatedPlane,alignment:.any)
        guard let hit=view.captureSession.arSession.raycast(query).first else{toolMessage="Поверхность не найдена. Осмотрите её с другого ракурса.";return}
        let p=hit.worldTransform.columns.3,end=SIMD3<Float>(p.x,p.y,p.z)
        guard simd_distance(origin,end)<=8 else{toolMessage="Подойдите ближе к точке замера";return}
        guard let start=measureStart else{measureStart=end;toolMessage="Первая точка выбрана. Наведите центр на вторую.";return}
        let distance=Double(simd_distance(start,end))
        guard distance>=0.05,distance<=30,let store,let project else{toolMessage="Слишком короткий или длинный размер. Выберите вторую точку ещё раз.";return}
        do{var record=Observation(projectId:project.id,kind:"object");record.title="Контрольный размер \(measureNumber+1)";record.measureLength=distance;record.measureMethod="ar";record.measurementFrameId=frameId;record.needsReview=true
            record.footprint=[[Double(start.x),Double(start.z),Double(start.y)],[Double(end.x),Double(end.z),Double(end.y)]]
            record.comments="Прямое расстояние между двумя указанными точками AR. Проверьте контрольным замером."
            try store.save(record);measureNumber+=1;measureStart=nil
            let material=SCNMaterial();material.diffuse.contents=UIColor.systemCyan;material.lightingModel = .constant
            let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:[SCNVector3(start.x,start.y,start.z),SCNVector3(end.x,end.y,end.z)])],elements:[SCNGeometryElement(indices:[UInt32(0),UInt32(1)],primitiveType:.line)]);geometry.materials=[material]
            measurementNode.addChildNode(SCNNode(geometry:geometry))
            let label=SCNText(string:String(format:"№%d · %.2f м",measureNumber,distance),extrusionDepth:0);label.font=UIFont.systemFont(ofSize:1,weight:.semibold);label.materials=[material]
            let node=SCNNode(geometry:label);node.scale=SCNVector3(0.035,0.035,0.035);node.simdPosition=(start+end)/2;node.constraints=[SCNBillboardConstraint()];measurementNode.addChildNode(node)
            toolMessage=String(format:"Размер №%d: %.2f м · сохранён",measureNumber,distance)
        }catch{self.error=error.localizedDescription}
    }
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
    func finishRoom(){guard scanning else{return};stopTorch();measureStart=nil;processingLevel=selectedLevel;scanning=false;processing=true;message="Строим план и сохраняем исходные измерения…";view.captureSession.stop(pauseARSession:false)}
    func pause(){stopTorch();if scanning{finishRoom()};view.captureSession.arSession.pause();newGroupOnResume=true;measurementNode.childNodes.forEach{$0.removeFromParentNode()}}
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
    @State private var showNote=false
    @State private var note=""
    @State private var showAssistant=false
    @Environment(\.verticalSizeClass) private var sizeClass
    var body:some View{
        ZStack(alignment:.bottom){
            if controller.supported{InteriorCaptureCamera(controller:controller).ignoresSafeArea();RoomSurfaceCamera(controller:controller).ignoresSafeArea().allowsHitTesting(false)}
            else{ContentUnavailableView("Съёмка помещения недоступна",systemImage:"viewfinder",description:Text("Нужен совместимый iPhone/iPad с LiDAR."))}
            if controller.scanning{Image(systemName:"plus").font(.title2).foregroundStyle(.white).shadow(radius:2).frame(maxWidth:.infinity,maxHeight:.infinity).allowsHitTesting(false)}
            VStack(spacing:8){
                if controller.scanning{Text("Стены: \(controller.liveWalls) · Проёмы: \(controller.liveOpenings)").font(.caption.monospacedDigit()).accessibilityIdentifier("room-live-progress")}
                HStack{Button("Этаж \(floorAdvisor.estimate.level) · изменить"){floorChoice=floorAdvisor.estimate.level;editFloor=true};Spacer();if let proposed=floorAdvisor.estimate.proposal{Button("Возможно, этаж \(proposed)"){floorChoice=proposed;editFloor=true}.tint(.orange)}}.font(.caption)
                Text(controller.message).font(.callout).frame(maxWidth:.infinity,alignment:.leading)
                if controller.processing{ProgressView("Обработка комнаты")}
                if controller.scanning{
                    Text(controller.toolMessage).font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:8){
                        tool(controller.measureStart == nil ? "Размер":"Точка 2","ruler"){controller.measurePoint()}
                        tool("Фото","camera"){controller.takePhoto()}
                        tool("Заметка","note.text"){note="";showNote=true}
                        tool("x0","sparkles"){showAssistant=true}
                    }
                    HStack{Button(controller.coverageVisible ? "Скрыть штриховку":"Показать штриховку"){controller.toggleCoverage()};Spacer();Button(controller.torchOn ? "Фонарь выкл.":"Фонарь вкл."){controller.toggleTorch()}}.font(.caption).frame(minHeight:44)
                    if controller.measureStart != nil{Button("Отменить первую точку"){controller.clearMeasure()}.font(.caption)}
                    Button("Сохранить комнату / перерыв"){controller.finishRoom()}.buttonStyle(.borderedProminent)
                }
                else if !controller.processing{
                    if controller.latest == nil && !controller.hasUnsaved && controller.supported{Button("Начать комнату заново"){controller.startRoom()}.buttonStyle(.bordered)}
                    if controller.latest != nil{HStack{Button("План и размеры"){review=true};Button("Следующая комната"){controller.startRoom()}}.buttonStyle(.bordered);Button("Собрать план квартиры / дома"){Task{await controller.exportStructure()}}.buttonStyle(.bordered)}
                    if controller.hasUnsaved{Button("Повторить сохранение"){controller.persistResult()}}
                    Button("Готово"){controller.pause();dismiss()}.buttonStyle(.borderedProminent).disabled(controller.hasUnsaved)
                }
                if !controller.scanning{Text("Размеры привязаны к стенам и проёмам. Потолок измеряется отдельно.").font(.caption).foregroundStyle(.secondary)}
            }.padding(12).frame(maxWidth:sizeClass == .compact ? 360:520).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20)).padding(12).frame(maxWidth:.infinity,alignment:sizeClass == .compact ? .trailing:.center)
        }.onAppear{controller.configure(store:store,project:project)}.onDisappear{controller.pause();floorAdvisor.stop()}
        .onChange(of:phase){_,value in if value != .active{controller.pause();floorAdvisor.stop()}}
        .onChange(of:health.stopReason){_,reason in if let reason,controller.scanning{controller.finishRoom();controller.message=reason}}
        .alert("Заметка помещения",isPresented:$showNote){TextField("Что нужно зафиксировать?",text:$note);Button("Сохранить"){controller.addNote(note)};Button("Отмена",role:.cancel){}}
        .sheet(isPresented:$showAssistant){FieldAssistantView(project:project,context:"Идёт съёмка помещения RoomPlan. Стен: \(controller.liveWalls), проёмов: \(controller.liveOpenings). Этаж: \(controller.selectedLevel). Подсказка сканера: \(controller.message)")}
        .fullScreenCover(isPresented:$review){if let doc=controller.latest{NativeRoomPlanReview(document:doc,onLevelChange:controller.changeLevel,project:project,onCeilingStart:controller.pause,onCeilingChange:controller.changeCeiling)}}
        .sheet(isPresented:$editFloor){NavigationStack{Form{
            Section("Этаж текущей / следующей комнаты"){Stepper("Этаж \(floorChoice)",value:$floorChoice,in:-20...200);Text("Можно указать отрицательный уровень или 0 для цоколя. Сохранённые комнаты редактируются в их плане.").font(.footnote)}
            Section("Подсказка по высоте"){Text(floorAdvisor.message);Text("Изменение давления — только подсказка. Перепад высоты не определяет этаж точно.").font(.footnote);Button(floorAdvisor.active ? "Выключить подсказки":"Включить подсказки барометра"){if floorAdvisor.active{floorAdvisor.stop()}else{floorAdvisor.start()}}}
        }.navigationTitle("Выбор этажа").toolbar{ToolbarItem(placement:.cancellationAction){Button("Отмена"){editFloor=false}};ToolbarItem(placement:.confirmationAction){Button("Подтвердить"){floorAdvisor.confirm(floorChoice);controller.selectedLevel=floorChoice;editFloor=false}}}}}
        .alert("Проверка помещения",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){Button("Повторить сохранение"){controller.persistResult()};Button("Понятно"){controller.error=nil}}message:{Text(controller.error ?? "")}
    }
    private func tool(_ title:String,_ symbol:String,action:@escaping()->Void)->some View{
        Button(action:action){VStack(spacing:4){Image(systemName:symbol);Text(title).font(.caption2)}.frame(maxWidth:.infinity,minHeight:44)}.buttonStyle(.bordered)
    }
}
