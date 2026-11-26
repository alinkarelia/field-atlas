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
    override init(){super.init();view.delegate=self;view.captureSession.delegate=self;view.isModelEnabled=false}
    required init?(coder:NSCoder){super.init();view.delegate=self;view.captureSession.delegate=self;view.isModelEnabled=false}
    func encode(with coder:NSCoder){}
    func configure(store:AppStore,project:FieldProject){guard self.project?.id != project.id else{return};self.store=store;self.project=project;surfaceView.scene?.rootNode.addChildNode(measurementNode);startRoom()}
    func toggleCoverage(){coverageVisible.toggle();surfaceView.surfaces.root.isHidden = !coverageVisible}
    func toggleTorch(){
        do{torchOn=try CaptureLight.toggle()}catch{self.error=error.localizedDescription}
    }
    func stopTorch(){do{try CaptureLight.turnOff();torchOn=false}catch{self.error="Не удалось выключить фонарь: "+error.localizedDescription}}
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
            try store.save(record);UIImpactFeedbackGenerator(style:.light).impactOccurred();toolMessage="Фотография сохранена в объектах проекта"
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
    func startRoom(){guard supported,!scanning,!processing,unsaved==nil else{return};if let root=store?.root,let reason=DeviceReadiness.stopReason(free:DeviceReadiness.freeSpace(root),thermal:ProcessInfo.processInfo.thermalState){message=reason;return};if newGroupOnResume{frameId=UUID().uuidString;captured=[];savedCount=0;latest=nil;newGroupOnResume=false};surfaceView.surfaces.reset();liveWalls=0;liveOpenings=0;var config=RoomCaptureSession.Configuration();config.isCoachingEnabled=false;view.captureSession.run(configuration:config);scanning=true;message="Снимите все стены, затем окна и проходы. Состояние и подсказки доступны через значок «?»."}
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
    @StateObject private var floorAdvisor=FloorAdvisor()
    @State private var review=false
    @State private var editFloor=false
    @State private var floorChoice=1
    @State private var showNote=false
    @State private var note=""
    @State private var showAssistant=false
    @State private var pendingAssistant=false
    @State private var showHelp=false
    @State private var showMore=false
    @State private var showResult=false
    @State private var closeRequested=false
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            InteriorCaptureCamera(controller:controller).ignoresSafeArea()
            RoomSurfaceCamera(controller:controller).ignoresSafeArea().allowsHitTesting(false)
            if controller.measureStart != nil{Image(systemName:"plus").foregroundStyle(.white).shadow(radius:2).allowsHitTesting(false)}
            CaptureHUD {
                CaptureTool(symbol:"xmark",label:"Сохранить и закрыть камеру",id:"capture-close",busy:controller.processing){closeCapture()}.disabled(controller.processing)
                CaptureTool(symbol:controller.torchOn ? "flashlight.on.fill":"flashlight.off.fill",label:"Фонарик",id:"capture-torch",active:controller.torchOn){controller.toggleTorch()}.disabled(!controller.scanning)
                CaptureTool(symbol:"square.3.layers.3d",label:"Штриховка стен",id:"capture-coverage",active:controller.coverageVisible){controller.toggleCoverage()}
                CaptureTool(symbol:"questionmark",label:"Инструменты и состояние съёмки",id:"capture-help"){showHelp=true}
            } right: {
                CaptureTool(symbol:controller.scanning ? "checkmark":"play.fill",label:controller.scanning ? "Сохранить комнату":"Комнаты и продолжение",id:"room-save",active:controller.scanning,busy:controller.processing){if controller.scanning{controller.finishRoom()}else{showResult=true}}.disabled(controller.processing)
                CaptureTool(symbol:"ruler",label:controller.measureStart == nil ? "Измерить: первая точка в центре":"Измерить: вторая точка в центре",id:"room-measure",active:controller.measureStart != nil){controller.measurePoint()}.disabled(!controller.scanning)
                CaptureTool(symbol:"camera.fill",label:"Сохранить фотографию помещения",id:"room-photo"){controller.takePhoto()}.disabled(!controller.scanning)
                CaptureTool(symbol:"ellipsis",label:"Этаж, заметка и другие инструменты",id:"room-more"){showMore=true}
                CaptureTool(symbol:"x0",label:"Помощник x0",id:"capture-assistant"){if controller.scanning{pendingAssistant=true;controller.finishRoom()}else{showAssistant=true}}.disabled(controller.processing)
            }
        }.statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear{controller.configure(store:store,project:project)}
        // Reviewing the saved plan must not reset the coordinate frame or start a new room.
        // Ceiling capture explicitly calls pause because it takes over the AR camera.
        .onDisappear{if !review{controller.pause()};floorAdvisor.stop()}
        .onChange(of:phase){_,value in if value != .active{controller.pause();floorAdvisor.stop()}else if !controller.scanning && !controller.processing{showResult=true}}
        .onChange(of:health.stopReason){_,reason in if let reason,controller.scanning{controller.finishRoom();controller.message=reason}}
        .onChange(of:controller.processing){_,processing in
            if !processing {
                if closeRequested && !controller.hasUnsaved && controller.error == nil{dismiss()}
                else if pendingAssistant{pendingAssistant=false;showAssistant=true}
                else{closeRequested=false;showResult=true}
            }
        }
        .alert("Заметка помещения",isPresented:$showNote){TextField("Что нужно зафиксировать?",text:$note);Button("Сохранить"){controller.addNote(note)};Button("Отмена",role:.cancel){}}
        .sheet(isPresented:$showHelp){CaptureHelp(title:"Съёмка комнаты",status:"\(controller.message)\nСтен: \(controller.liveWalls) · Проёмов: \(controller.liveOpenings)\n\(controller.toolMessage)",items:[
            ("flashlight.on.fill","Фонарик","Кнопка слева. Жёлтый значок — свет включён."),
            ("square.3.layers.3d","Покрытие","Штриховка появляется на распознанных стенах: зелёная — высокая уверенность, оранжевая — осмотрите ещё. Двери и окна остаются открытыми."),
            ("checkmark","Сохранить комнату","Завершает обмер и открывает проверку. Оттуда можно перейти в следующую комнату."),
            ("ruler","Контрольный размер","Наведите центр на первую точку и нажмите линейку. Затем наведите на вторую и нажмите ещё раз. Размер подписывается на линии."),
            ("camera.fill","Фото","Сохраняет текущий кадр отдельным объектом проекта. Короткая вибрация подтверждает сохранение."),
            ("ellipsis","Дополнительно","Этаж, заметка, отмена точки измерения и сохранённые комнаты."),
            ("x0","Помощник","Текущая комната сначала сохраняется. x0 помогает с вопросами; отправку материалов подтверждаете вы.")
        ])}
        .sheet(isPresented:$showMore){NavigationStack{List{
            Section("Текущая комната"){
                Button("Этаж \(controller.selectedLevel) · изменить"){floorChoice=floorAdvisor.estimate.level;showMore=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){editFloor=true}}
                if let proposed=floorAdvisor.estimate.proposal{Text("Барометр предлагает этаж \(proposed). Подтвердите вручную.")}
                Button("Добавить заметку"){showMore=false;note="";DispatchQueue.main.asyncAfter(deadline:.now()+0.3){showNote=true}}
                Button("Отменить первую точку размера"){controller.clearMeasure();showMore=false}.disabled(controller.measureStart==nil)
            }
            Section("Состояние"){Text(controller.toolMessage);Text(controller.message);LabeledContent("Стен / проёмов",value:"\(controller.liveWalls) / \(controller.liveOpenings)")}
        }.navigationTitle("Инструменты").toolbar{Button("К камере"){showMore=false}}}}
        .sheet(isPresented:$showResult){resultView.interactiveDismissDisabled(controller.hasUnsaved)}
        .sheet(isPresented:$showAssistant,onDismiss:{showResult=true}){FieldAssistantView(project:project,context:"Помещение RoomPlan. Стен: \(controller.liveWalls), проёмов: \(controller.liveOpenings). Этаж: \(controller.selectedLevel). \(controller.message)")}
        .fullScreenCover(isPresented:$review,onDismiss:{if !controller.scanning && !controller.processing{showResult=true}}){if let doc=controller.latest{NativeRoomPlanReview(document:doc,onLevelChange:controller.changeLevel,project:project,onCeilingStart:controller.pause,onCeilingChange:controller.changeCeiling)}}
        .sheet(isPresented:$editFloor){NavigationStack{Form{
            Section("Этаж текущей / следующей комнаты"){Stepper("Этаж \(floorChoice)",value:$floorChoice,in:-20...200);Text("0 — цоколь; отрицательные номера — подземные уровни. Сохранённые комнаты редактируются в плане.").font(.footnote)}
            Section("Подсказка по высоте"){Text(floorAdvisor.message);Text("Перепад давления — только подсказка; этаж подтверждается вручную.").font(.footnote);Button(floorAdvisor.active ? "Выключить подсказки":"Включить подсказки барометра"){if floorAdvisor.active{floorAdvisor.stop()}else{floorAdvisor.start()}}}
        }.navigationTitle("Выбор этажа").toolbar{ToolbarItem(placement:.cancellationAction){Button("Отмена"){editFloor=false}};ToolbarItem(placement:.confirmationAction){Button("Подтвердить"){floorAdvisor.confirm(floorChoice);controller.selectedLevel=floorChoice;editFloor=false}}}}}
        .alert("Съёмка помещения",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){if controller.hasUnsaved{Button("Повторить сохранение"){controller.error=nil;controller.persistResult()}};Button("Понятно"){controller.error=nil}}message:{Text(controller.error ?? "")}
    }
    private var resultView:some View {
        NavigationStack{List{
            Section {Label(controller.hasUnsaved ? "Нужно повторить сохранение":controller.latest == nil ? "Съёмка приостановлена":"Комната сохранена",systemImage:controller.hasUnsaved ? "exclamationmark.triangle":"checkmark.circle").font(.headline);Text(controller.message)}
            Section("Дальше") {
                if controller.hasUnsaved{Button("Повторить сохранение"){controller.persistResult()}}
                if controller.latest != nil {
                    Button("Проверить план и размеры"){showResult=false;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){review=true}}
                    Button("Собрать план квартиры / дома"){Task{await controller.exportStructure()}}.disabled(controller.processing)
                }
                Button(controller.latest == nil ? "Повторить съёмку комнаты":"Снимать следующую комнату"){controller.startRoom();if controller.scanning{showResult=false}}.disabled(controller.hasUnsaved || controller.processing)
                Button("Вернуться к проекту"){showResult=false;dismiss()}.disabled(controller.hasUnsaved || controller.processing)
            }
            if controller.processing{ProgressView("Обработка")}
        }.navigationTitle("Результат обмера").navigationBarTitleDisplayMode(.inline)}
    }
    private func closeCapture(){
        if controller.scanning{closeRequested=true;controller.finishRoom()}
        else if controller.hasUnsaved{showResult=true}
        else if !controller.processing{dismiss()}
    }
}
