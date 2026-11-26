import ARKit
import SceneKit
import SwiftUI
import CoreImage
import FieldCore

@MainActor final class CaptureController: NSObject,ObservableObject,ARSessionDelegate {
    let view=ARSCNView(frame:.zero)
    @Published var status="Подготовка камеры"
    @Published var recording=false
    @Published var pointCount=0
    @Published var savedChunks=0
    @Published var canReset=false
    @Published var torchOn=false
    @Published var coverageVisible=true
    @Published var error: String?
    @Published var measurementPoints:[[Double]]=[]
    var currentFrameId:String{frameId}
    var measuredArea:Double{Geometry.area(measurementPoints.map{[$0[0],$0[1]]})}
    private var store: AppStore?
    private var projectId=""
    private var frameId=UUID().uuidString
    private var points: [[Double]]=[]
    private var preview=SurfacePreview()
    private let surfaces=SurfaceOverlay()
    private var controls: [String:[Double]]=[:]
    private var sourceFrames: [String]=[]
    private var lastSample: TimeInterval=0
    private var lastImage: TimeInterval=0
    private var sessionEpoch=0
    private var recovered=false
    private var cloudNode=SCNNode()
    private let ci=CIContext(options:[.cacheIntermediates:false])
    var supportsLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    func toggleTorch(){do{torchOn=try CaptureLight.toggle()}catch{self.error=error.localizedDescription}}
    func toggleCoverage(){coverageVisible.toggle();surfaces.root.isHidden = !coverageVisible;cloudNode.isHidden = !coverageVisible}
    func saveSector(){let count=savedChunks;flush();if savedChunks>count{UIImpactFeedbackGenerator(style:.light).impactOccurred();status="Сектор сохранён. Продолжайте с небольшим перекрытием."}}
    private func stopTorch(){do{try CaptureLight.turnOff();torchOn=false}catch{self.error="Не удалось выключить фонарь: "+error.localizedDescription}}
    override init(){super.init();view.session.delegate=self;view.scene=SCNScene();view.scene.rootNode.addChildNode(cloudNode);view.scene.rootNode.addChildNode(surfaces.root);view.automaticallyUpdatesLighting=false}
    func configure(store: AppStore,project: FieldProject){self.store=store;projectId=project.id;start()}
    func start(fresh: Bool=false){
        finishing=false;sessionEpoch+=1
        flush();guard !hasUnsavedPoints else{status="Сначала сохраните предыдущую часть";return}
        if fresh{controls=[:];measurementPoints=[];error=nil}
        if let root=store?.root,let reason=DeviceReadiness.stopReason(free:DeviceReadiness.freeSpace(root),thermal:ProcessInfo.processInfo.thermalState){status=reason;return}
        guard supportsLiDAR else{status="Для съёмки нужен iPhone/iPad с LiDAR";return}
        let config=ARWorldTrackingConfiguration();config.frameSemantics=[.sceneDepth]
        // No plane detection: preserve depth instead of flattening floor geometry.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh){config.sceneReconstruction = .mesh}
        recovered=false;canReset=false
        if !fresh,let store,let ref=store.state.worldMaps[projectId]{
            do{
                let url=store.root.appendingPathComponent("assets").appendingPathComponent(ref.filename)
                guard let map=try NSKeyedUnarchiver.unarchivedObject(ofClass:ARWorldMap.self,from:Data(contentsOf:url)) else{throw CocoaError(.coderReadCorrupt)}
                config.initialWorldMap=map;frameId=ref.frameId;preview=store.loadPreview(projectId:projectId,frameId:frameId);canReset=true
                status="Найдите прежние ориентиры для продолжения"
            }catch{frameId=UUID().uuidString;controls=[:];measurementPoints=[];preview=SurfacePreview();status="Прежняя привязка недоступна. Новая сессия."}
        }else{frameId=UUID().uuidString;controls=[:];measurementPoints=[];preview=SurfacePreview();status="Медленно осмотрите окружение"}
        surfaces.reset();cloudNode.geometry=nil;view.session.run(config,options:[.resetTracking,.removeExistingAnchors]);recording=true
    }
    func toggle(){
        guard view.session.currentFrame != nil else{start();return}
        if recording{flush();recording=false;status=hasUnsavedPoints ? "Пауза · часть не сохранена, повторите сохранение":"Пауза · данные сохранены"}
        else{if let root=store?.root,let reason=DeviceReadiness.stopReason(free:DeviceReadiness.freeSpace(root),thermal:ProcessInfo.processInfo.thermalState){status=reason;return};recording=true;status="Съёмка продолжается"}
    }
    nonisolated func session(_ session: ARSession,didUpdate frame: ARFrame){Task{@MainActor [weak self] in self?.process(frame)}}
    nonisolated func session(_ session: ARSession,didFailWithError error: Error){Task{@MainActor [weak self] in self?.stopTorch();self?.recording=false;self?.error="Камера остановлена: \(error.localizedDescription)";self?.flush()}}
    nonisolated func sessionWasInterrupted(_ session: ARSession){Task{@MainActor [weak self] in self?.stopTorch();self?.recording=false;self?.flush();self?.status="Съёмка прервана. Сохранённые части доступны."}}
    private func process(_ frame: ARFrame){
        guard recording else{return}
        guard case .normal=frame.camera.trackingState else{
            switch frame.camera.trackingState{case .limited(.excessiveMotion):status="Двигайтесь медленнее — кадр смазан";case .limited(.insufficientFeatures):status="Добавьте свет и наведитесь на поверхность с деталями";case .limited(.relocalizing):status="Найдите прежние ориентиры";default:status="Уточняем положение · новые поверхности не засчитываются"};return
        }
        if !recovered{recovered=true;renderPreview();canReset=false}
        surfaces.updateMeshes(frame)
        guard frame.timestamp-lastSample>0.8,let depth=frame.sceneDepth,let confidence=depth.confidenceMap else{return}
        guard ProcessInfo.processInfo.thermalState != .critical && ProcessInfo.processInfo.thermalState != .serious else{stopTorch();flush();recording=false;status="Пауза: устройству нужно остыть";return}
        if let root=store?.root,let free=try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,free<200_000_000{flush();recording=false;status=hasUnsavedPoints ? "Недостаточно места. Часть остаётся в памяти — не закрывайте приложение.":"Недостаточно места. Части сохранены.";return}
        lastSample=frame.timestamp
        let buffer=depth.depthMap
        CVPixelBufferLockBaseAddress(buffer,.readOnly);CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly);CVPixelBufferUnlockBaseAddress(confidence,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(buffer),let quality=CVPixelBufferGetBaseAddress(confidence) else{return}
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),row=CVPixelBufferGetBytesPerRow(buffer),qrow=CVPixelBufferGetBytesPerRow(confidence)
        let k=frame.camera.intrinsics,res=frame.camera.imageResolution
        let sx=Float(width)/Float(res.width),sy=Float(height)/Float(res.height),fx=k[0][0]*sx,fy=k[1][1]*sy,cx=k[2][0]*sx,cy=k[2][1]*sy
        var sample: [[Double]]=[]
        for v in stride(from:0,to:height,by:4){for u in stride(from:0,to:width,by:4){
            let z=base.advanced(by:v*row).assumingMemoryBound(to:Float32.self)[u]
            let q=quality.advanced(by:v*qrow).assumingMemoryBound(to:UInt8.self)[u]
            guard z.isFinite,z>0.2,z<4.5,q>=1 else{continue}
            let local=SIMD4<Float>((Float(u)-cx)*z/fx,-(Float(v)-cy)*z/fy,-z,1)
            let world=frame.camera.transform*local
            sample.append([Double(world.x),Double(world.z),Double(world.y),Double(q)])
        }}
        points.append(contentsOf:sample);preview.add(sample);pointCount+=sample.count
        status="Измерено \(pointCount) точек · \(savedChunks) частей сохранено"
        // Keep calibrated original depth alongside the bounded preview, at selected keyframes.
        if frame.timestamp-lastImage>4,let store{
            do{
                let raw=Data(bytes:base,count:row*height)
                let da=try store.saveAsset(raw,projectId:projectId,mime:"application/octet-stream",extension:"bin")
                let qa=try store.saveAsset(Data(bytes:quality,count:qrow*height),projectId:projectId,mime:"application/octet-stream",extension:"bin")
                let image=CIImage(cvPixelBuffer:frame.capturedImage)
                let rgb=ci.jpegRepresentation(of:image,colorSpace:CGColorSpaceCreateDeviceRGB(),options:[:])
                let ra=try rgb.map{try store.saveAsset($0,projectId:projectId,mime:"image/jpeg",extension:"jpg")}
                let transform=(0..<4).flatMap{col in (0..<4).map{row in Double(frame.camera.transform[col][row])}}
                let meta: [String:Any]=["schema":"field-depth-frame-v1","frameId":frameId,"timestamp":frame.timestamp,"width":width,"height":height,"bytesPerRow":row,"confidenceBytesPerRow":qrow,"depth":"float32-little-endian-metres","depthAssetId":da.id,"confidenceAssetId":qa.id,"rgbAssetId":ra?.id ?? "","cameraTransformColumnMajor":transform,"intrinsics":[Double(fx),Double(fy),Double(cx),Double(cy)],"pointAxes":"world-x,world-z,world-y"]
                let ma=try store.saveAsset(JSONSerialization.data(withJSONObject:meta),projectId:projectId,mime:"application/json",extension:"json");sourceFrames.append(ma.id);lastImage=frame.timestamp
            }catch{self.error="Не удалось сохранить исходные измерения. Съёмка приостановлена.";recording=false}
        }
        renderPreview();if points.count>=20000{flush()}
    }
    private func renderPreview(){
        guard recovered else{return}
        let visible=preview.points
        let vertices=visible.map{SCNVector3(Float($0[0]),Float($0[2]),Float($0[1]))}
        guard !vertices.isEmpty else{cloudNode.geometry=nil;return}
        let source=SCNGeometrySource(vertices:vertices)
        let indices=(0..<vertices.count).map{UInt32($0)}
        let element=SCNGeometryElement(indices:indices,primitiveType:.point);element.pointSize=6;element.minimumPointScreenSpaceRadius=2;element.maximumPointScreenSpaceRadius=5
        let colors=visible.flatMap{p->[Float] in p[3]>=2 ? [0.38,0.84,0.42,0.75]:[0.95,0.72,0.25,0.75]}
        let data=colors.withUnsafeBufferPointer{Data(buffer:$0)}
        let color=SCNGeometrySource(data:data,semantic:.color,vectorCount:vertices.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let geometry=SCNGeometry(sources:[source,color],elements:[element]);let material=SCNMaterial();material.lightingModel = .constant;material.diffuse.contents=UIColor.white;geometry.materials=[material];cloudNode.geometry=geometry
    }
    func markControl(name: String,screenPoint: CGPoint){
        guard let frame=view.session.currentFrame,case .normal=frame.camera.trackingState else{status="Дождитесь устойчивой привязки";return}
        guard let query=view.raycastQuery(from:screenPoint,allowing:.estimatedPlane,alignment:.any),let result=view.session.raycast(query).first else{status="Поверхность ориентира не определена";return}
        let p=result.worldTransform.columns.3;controls[name]=[Double(p.x),Double(p.z),Double(p.y)];status="Ориентир \(name) сохранён"
    }
    func undoMeasurementCorner(){if !measurementPoints.isEmpty{measurementPoints.removeLast()}}
    func addMeasurementCorner(){
        guard let frame=view.session.currentFrame,case .normal=frame.camera.trackingState else{status="Дождитесь устойчивой привязки";return}
        let center=CGPoint(x:view.bounds.midX,y:view.bounds.midY)
        guard let query=view.raycastQuery(from:center,allowing:.estimatedPlane,alignment:.any),let result=view.session.raycast(query).first else{status="Угол не определён. Наведите центр на основание ограды.";return}
        let p=result.worldTransform.columns.3;measurementPoints.append([Double(p.x),Double(p.z),Double(p.y)])
        status="Углов: \(measurementPoints.count). Проверьте контур перед сохранением."
    }
    func flush(){
        guard !points.isEmpty,let store else{return}
        do{var chunk=ScanChunk(frameId:frameId,points:points,anchors:controls);chunk.sourceFrameIds=sourceFrames;try store.saveScan(chunk,projectId:projectId);points=[];sourceFrames=[];savedChunks+=1}
        catch{self.error="Часть не сохранена: \(error.localizedDescription)";recording=false}
    }
    var hasUnsavedPoints:Bool{!points.isEmpty}
    private var finishing=false
    @Published private(set) var savingMap=false
    func finish(){
        stopTorch()
        guard !finishing else{return};finishing=true
        recording=false;flush();if hasUnsavedPoints{finishing=false;return}
        savingMap=true
        guard let frame=view.session.currentFrame,case .normal=frame.camera.trackingState else{view.session.pause();savingMap=false;return}
        let fid=frameId,pid=projectId,epoch=sessionEpoch
        view.session.getCurrentWorldMap{[weak self] map,_ in
            Task{@MainActor in
                guard let self,self.sessionEpoch==epoch else{return}
                if let map,let data=try? NSKeyedArchiver.archivedData(withRootObject:map,requiringSecureCoding:true){do{try self.store?.saveWorldMap(data,frameId:fid,projectId:pid)}catch{self.error="Привязка для продолжения не сохранена"}}
                self.view.session.pause();self.savingMap=false
            }
        }
    }
}
struct CaptureCamera: UIViewRepresentable {
    @ObservedObject var controller: CaptureController
    func makeUIView(context: Context)->ARSCNView{controller.view}
    func updateUIView(_ view: ARSCNView,context: Context){}
}
