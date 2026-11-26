import SwiftUI
import AVFoundation
import ARKit
import RoomPlan
import CoreMotion
import FieldCore

@MainActor final class DeviceReadiness:ObservableObject {
    @Published var freeBytes:Int64?
    @Published var battery:Float = -1
    @Published var thermal=ProcessInfo.processInfo.thermalState
    @Published var camera=AVCaptureDevice.authorizationStatus(for:.video)
    var stopReason:String?{Self.stopReason(free:freeBytes,thermal:thermal)}
    static func stopReason(free:Int64?,thermal:ProcessInfo.ThermalState)->String?{
        if thermal == .serious || thermal == .critical{return "Устройству нужно остыть. Съёмка приостановлена."}
        if let free,free<200_000_000{return "Недостаточно свободного места. Освободите память перед продолжением."}
        return nil
    }
    static func freeSpace(_ root:URL)->Int64?{try? root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage}
    func refresh(_ root:URL){freeBytes=Self.freeSpace(root);battery=UIDevice.current.batteryLevel;thermal=ProcessInfo.processInfo.thermalState;camera=AVCaptureDevice.authorizationStatus(for:.video)}
    func monitor(_ root:URL)async{
        let prior=UIDevice.current.isBatteryMonitoringEnabled;UIDevice.current.isBatteryMonitoringEnabled=true
        defer{UIDevice.current.isBatteryMonitoringEnabled=prior}
        while !Task.isCancelled{refresh(root);try? await Task.sleep(nanoseconds:2_000_000_000)}
    }
}

struct CapturePreparationScreen:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var phase
    let project:FieldProject
    var onMeasurement:(([[Double]],Double,String)->Void)?=nil
    var onCeiling:((CeilingMeasurement)throws->Void)?=nil
    @StateObject private var health=DeviceReadiness()
    @State private var started=false
    @State private var checking=true
    private var supported:Bool{ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) && (project.type != .interior || onMeasurement != nil || onCeiling != nil || RoomCaptureSession.isSupported)}
    private var blocked:String {
        if !supported{return "На этом устройстве нет доступного LiDAR. Карта, фотографии и карточки работают отдельно от 3D-съёмки."}
        if health.camera != .authorized{return "Разрешите доступ к камере в настройках, затем вернитесь сюда."}
        return health.stopReason ?? "Камера готовится к работе"
    }
    var body:some View {
        Group {
            if started {
                if let onCeiling{CeilingCaptureScreen(onSave:onCeiling)}
                else if project.type == .interior && onMeasurement == nil{InteriorCaptureScreen(project:project)}
                else{CaptureScreen(project:project,onMeasurement:onMeasurement)}
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing:20) {
                        if checking {ProgressView().tint(.white)}
                        else {
                            Image(systemName:supported ? "camera.fill":"viewfinder").font(.largeTitle)
                            Text(supported ? "Камера недоступна":"LiDAR недоступен").font(.title2.bold()).accessibilityIdentifier("capture-unavailable")
                            Text(blocked).multilineTextAlignment(.center)
                            if supported && health.camera == .denied {Button("Открыть настройки"){if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}}.buttonStyle(.borderedProminent)}
                            if supported && health.camera == .authorized {Button("Проверить снова"){Task{await enter()}}.buttonStyle(.bordered)}
                        }
                    }.padding(32).frame(maxWidth:480).foregroundStyle(.white)
                    VStack{HStack{CaptureTool(symbol:"xmark",label:"Закрыть",id:"capture-close"){dismiss()};Spacer()};Spacer()}.padding(16)
                }
            }
        }.environmentObject(health).statusBarHidden(true).persistentSystemOverlays(.hidden)
        .task {await enter()}
        .task {await health.monitor(store.root)}
        .onChange(of:phase){_,value in if value == .active && !started{Task{await enter()}}}
    }
    private func enter()async {
        checking=true;defer{checking=false}
        health.refresh(store.root)
        guard supported else{return}
        if health.camera == .notDetermined{_ = await AVCaptureDevice.requestAccess(for:.video)}
        health.refresh(store.root)
        started=health.camera == .authorized && health.stopReason == nil
    }
}

@MainActor final class FloorAdvisor:ObservableObject {
    @Published private(set) var estimate=FloorSuggestion()
    @Published private(set) var active=false
    @Published private(set) var message="Этаж можно указать вручную"
    private let altimeter=CMAltimeter()
    func start(){
        guard CMAltimeter.isRelativeAltitudeAvailable() else{message="Барометр недоступен. Укажите этаж вручную.";return}
        guard CMAltimeter.authorizationStatus() != .denied && CMAltimeter.authorizationStatus() != .restricted else{message="Нет доступа к барометру. Ручной выбор работает.";return}
        estimate.restart();active=true;message="Следим за изменением высоты; этаж подтверждаете вы"
        altimeter.startRelativeAltitudeUpdates(to:.main){[weak self] data,error in
            Task{@MainActor in guard let self else{return};if error != nil{self.stop();self.message="Подсказки недоступны. Выберите этаж вручную.";return};if let data,self.active{self.estimate.update(height:data.relativeAltitude.doubleValue,time:data.timestamp)}}
        }
    }
    func stop(){altimeter.stopRelativeAltitudeUpdates();active=false;estimate.restart();message="Подсказки приостановлены. Номер этажа сохранён."}
    func confirm(_ level:Int){estimate.confirm(level)}
}
