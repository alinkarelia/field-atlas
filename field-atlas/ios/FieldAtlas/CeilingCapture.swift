import SwiftUI
import ARKit
import SceneKit
import FieldCore

@MainActor final class CeilingCaptureController:NSObject,ObservableObject,ARSessionDelegate {
    let view=ARSCNView(frame:.zero)
    private let overlay=SCNNode()
    let frameId=UUID().uuidString
    @Published var floor:[Double]?
    @Published var corners:[[Double]]=[]
    @Published var message="Осмотрите пол и потолок, затем укажите точку пола"
    @Published var method="manual-corners"
    @Published var stopped=false
    @Published var torchOn=false
    func toggleTorch(){do{torchOn=try CaptureLight.toggle()}catch{message=error.localizedDescription}}
    override init(){super.init();view.scene=SCNScene();view.scene.rootNode.addChildNode(overlay);view.session.delegate=self}
    func start(){let config=ARWorldTrackingConfiguration();config.planeDetection=[.horizontal,.vertical];if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification){config.sceneReconstruction = .meshWithClassification};if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth){config.frameSemantics=[.sceneDepth]};view.session.run(config);stopped=false}
    func stop(){do{try CaptureLight.turnOff();torchOn=false}catch{message=error.localizedDescription};view.session.pause();stopped=true;message="Сессия остановлена. Сохраните замер или начните новый."}
    nonisolated func sessionWasInterrupted(_ session:ARSession){Task{@MainActor [weak self] in self?.stop()}}
    nonisolated func session(_ session:ARSession,didFailWithError error:Error){Task{@MainActor [weak self] in self?.stop();self?.message="Камера остановлена. Сохраните имеющиеся точки или закройте замер."}}
    private func hit()->[Double]?{
        guard !stopped,let frame=view.session.currentFrame,case .normal=frame.camera.trackingState else{message="Дождитесь устойчивой привязки камеры";return nil}
        guard let query=view.raycastQuery(from:CGPoint(x:view.bounds.midX,y:view.bounds.midY),allowing:.estimatedPlane,alignment:.any),let result=view.session.raycast(query).first else{message="Поверхность пока не распознана. Медленно осмотрите её.";return nil}
        let p=result.worldTransform.columns.3;return [Double(p.x),Double(p.z),Double(p.y)]
    }
    func floorPoint(){if let p=hit(){floor=p;corners=[];method="manual-corners";message="Теперь укажите углы потолка по порядку";draw()}}
    func corner(){guard let floor else{message="Сначала укажите точку пола";return};if let p=hit(){guard p[2]-floor[2]>=0.5 else{message="Точка слишком близко к уровню пола";return};corners.append(p);method="manual-corners";message="Углов потолка: \(corners.count)";draw()}}
    func undo(){if !corners.isEmpty{corners.removeLast()}else{floor=nil};draw()}
    func propose(){
        guard !stopped,let frame=view.session.currentFrame,case .normal=frame.camera.trackingState else{message="Дождитесь устойчивой привязки";return}
        let planes=frame.anchors.compactMap{$0 as? ARPlaneAnchor}
        func boundary(_ anchor:ARPlaneAnchor)->[[Double]]{anchor.geometry.boundaryVertices.map{p in let w=anchor.transform*SIMD4<Float>(p.x,p.y,p.z,1);return [Double(w.x),Double(w.z),Double(w.y)]}}
        if floor==nil,let anchor=planes.first(where:{$0.classification == .floor}){let c=anchor.center,p=anchor.transform*SIMD4<Float>(c.x,c.y,c.z,1);floor=[Double(p.x),Double(p.z),Double(p.y)]}
        guard floor != nil,let ceiling=planes.filter({$0.classification == .ceiling}).max(by:{Geometry.area(boundary($0).map{Array($0.prefix(2))})<Geometry.area(boundary($1).map{Array($0.prefix(2))})}) else{message="Пол или потолок не распознан. Можно указать точки вручную.";return}
        corners=boundary(ceiling);method="plane-proposal";message="Предложен выпуклый контур. Он может закрывать проёмы и захватывать лишнее — проверьте перед сохранением.";draw()
    }
    var result:CeilingMeasurement?{guard let floor else{return nil};let m=CeilingMeasurement(frameId:frameId,method:method,floorPoint:floor,points:corners);return m.valid ? m:nil}
    private func draw(){
        overlay.childNodes.forEach{$0.removeFromParentNode()}
        for p in corners+(floor.map{[$0]} ?? []){let node=SCNNode(geometry:SCNSphere(radius:0.025));node.position=SCNVector3(Float(p[0]),Float(p[2]),Float(p[1]));node.geometry?.firstMaterial?.diffuse.contents=UIColor.systemYellow;overlay.addChildNode(node)}
        guard corners.count>1 else{return};var vertices:[SCNVector3]=[]
        for i in corners.indices{for p in [corners[i],corners[(i+1)%corners.count]]{vertices.append(SCNVector3(Float(p[0]),Float(p[2]),Float(p[1])))}}
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:Array(0..<Int32(vertices.count)),primitiveType:.line)]);geometry.firstMaterial?.diffuse.contents=UIColor.systemYellow;overlay.addChildNode(SCNNode(geometry:geometry))
    }
}
private struct CeilingCamera:UIViewRepresentable {
    @ObservedObject var controller:CeilingCaptureController
    func makeUIView(context:Context)->ARSCNView{controller.view}
    func updateUIView(_ view:ARSCNView,context:Context){}
}
struct CeilingCaptureScreen:View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var phase
    @EnvironmentObject var health:DeviceReadiness
    let onSave:(CeilingMeasurement)throws->Void
    @StateObject private var controller=CeilingCaptureController()
    @State private var error:String?
    @State private var showHelp=false
    @State private var confirmSave=false
    var body:some View {
        ZStack {
            CeilingCamera(controller:controller).ignoresSafeArea()
            Image(systemName:"plus").font(.title2).foregroundStyle(.white).shadow(radius:2).allowsHitTesting(false)
            CaptureHUD {
                CaptureTool(symbol:"xmark",label:"Закрыть замер потолка",id:"capture-close"){dismiss()}
                CaptureTool(symbol:controller.torchOn ? "flashlight.on.fill":"flashlight.off.fill",label:"Фонарик",id:"capture-torch",active:controller.torchOn){controller.toggleTorch()}
                CaptureTool(symbol:"questionmark",label:"Как измерить потолок",id:"capture-help"){showHelp=true}
            } right: {
                CaptureTool(symbol:controller.stopped ? "play.fill":"arrow.down.to.line",label:controller.stopped ? "Продолжить замер":"Указать точку пола",id:"ceiling-floor",active:controller.floor != nil){if controller.stopped{controller.start()}else{controller.floorPoint()}}
                CaptureTool(symbol:"plus",label:"Добавить угол потолка",id:"ceiling-corner"){controller.corner()}.disabled(controller.floor==nil || controller.stopped)
                CaptureTool(symbol:"arrow.uturn.backward",label:"Убрать последнюю точку",id:"ceiling-undo"){controller.undo()}
                CaptureTool(symbol:"square.dashed",label:"Предложить распознанный контур",id:"ceiling-propose"){controller.propose();showHelp=true}
                CaptureTool(symbol:"checkmark",label:"Проверить и сохранить замер",id:"ceiling-save"){confirmSave=true}.disabled(controller.result==nil)
            }
        }.statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear{controller.start()}.onDisappear{controller.stop()}
        .onChange(of:phase){_,p in if p != .active{controller.stop()}}
        .onChange(of:health.stopReason){_,reason in if reason != nil{controller.stop()}}
        .sheet(isPresented:$showHelp){CaptureHelp(title:"Пол и потолок",status:"\(controller.message)\nУглов: \(controller.corners.count)",items:[("arrow.down.to.line","Точка пола","Наведите центр на пол и нажмите стрелку вниз."),("plus","Углы потолка","Наведите центр на каждый угол потолка по порядку и нажимайте плюс."),("square.dashed","Предложить контур","Используется только распознанная поверхность. Проверьте, не закрывает ли контур проёмы."),("checkmark","Проверить и сохранить","Высота рассчитывается над выбранной точкой пола. Для точной работы нужен контрольный промер.")])}
        .confirmationDialog("Сохранить измерение потолка?",isPresented:$confirmSave,titleVisibility:.visible){Button("Проверено — сохранить"){if let result=controller.result{do{try onSave(result);dismiss()}catch{self.error=error.localizedDescription}}};Button("Вернуться к замеру",role:.cancel){}}message:{Text(summary)}
        .alert("Замер не сохранён",isPresented:Binding(get:{error != nil},set:{if !$0{error=nil}})){Button("Понятно"){error=nil}}message:{Text(error ?? "")}
    }
    private var summary:String{if let result=controller.result,let low=result.heights.min(),let high=result.heights.max(){return String(format:"Высота над точкой пола: %.2f–%.2f м. Углов: %d. Это отдельная система координат; проверьте контур.",low,high,controller.corners.count)};return controller.message}
}
