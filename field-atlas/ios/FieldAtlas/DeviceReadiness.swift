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
    let project:FieldProject
    var onMeasurement:(([[Double]],Double,String)->Void)?=nil
    var onCeiling:((CeilingMeasurement)throws->Void)?=nil
    @StateObject private var health=DeviceReadiness()
    @State private var started=false
    private var supported:Bool{ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) && (project.type != .interior || onMeasurement != nil || onCeiling != nil || RoomCaptureSession.isSupported)}
    var body:some View{
        Group{
            if started{
                if let onCeiling{CeilingCaptureScreen(onSave:onCeiling)}else if project.type == .interior && onMeasurement == nil{InteriorCaptureScreen(project:project)}else{CaptureScreen(project:project,onMeasurement:onMeasurement)}
            }else{
                NavigationStack{List{
                    Section("Съёмка на этом устройстве"){
                        LabeledContent("LiDAR",value:supported ? "Доступен":"Недоступен")
                        LabeledContent("Движение и камера",value:"Совместная привязка ARKit")
                        LabeledContent("Камера",value:health.camera == .authorized ? "Разрешена":health.camera == .notDetermined ? "Запрос при старте":"Разрешите в настройках")
                        LabeledContent("Свободно",value:health.freeBytes.map{ByteCountFormatter.string(fromByteCount:$0,countStyle:.file)} ?? "Не удалось проверить")
                        LabeledContent("Заряд",value:health.battery>=0 ? "\(Int(health.battery*100))%":"Неизвестен")
                        LabeledContent("Нагрев",value:health.thermal == .nominal ? "Нормальный":health.thermal == .fair ? "Повышенный":"Нужна пауза")
                    }
                    Section{
                        if let reason=health.stopReason{Text(reason).foregroundStyle(.orange)}
                        if health.battery>=0 && health.battery<0.15{Text("Низкий заряд. Сохраняйте короткими частями; по возможности подключите питание.").foregroundStyle(.orange)}
                        Text(project.type == .interior ? "В помещении используются камера, LiDAR и датчики движения. Этаж можно указать вручную или включить подсказки барометра. GPS не задаёт размеры комнаты.":"GPS используется для карты с учётом погрешности. Геометрию скана удерживают ARKit и LiDAR; привязка скана к карте выполняется отдельно.")
                    }
                    Section{
                        Button("Начать съёмку"){Task{if health.camera == .notDetermined{_ = await AVCaptureDevice.requestAccess(for:.video)};health.refresh(store.root);if health.camera == .authorized && health.stopReason==nil{started=true}}}.disabled(!supported || health.stopReason != nil || health.camera == .denied || health.camera == .restricted).accessibilityIdentifier("capture-start")
                        if health.camera == .denied{Button("Настройки камеры"){if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}}}
                    }
                }.navigationTitle("Готовность к съёмке").toolbar{Button("Закрыть"){dismiss()}}}
            }
        }.environmentObject(health).task{await health.monitor(store.root)}
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
