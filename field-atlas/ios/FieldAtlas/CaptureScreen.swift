import SwiftUI
import FieldCore

struct CaptureScreen:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var phase
    let project:FieldProject
    var onMeasurement:(([[Double]],Double,String)->Void)?=nil
    @StateObject private var controller=CaptureController()
    @State private var showControl=false
    @State private var controlName=""
    @State private var closeRequested=false
    @State private var showHelp=false
    @State private var showAssistant=false
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CaptureCamera(controller:controller).ignoresSafeArea()
            if onMeasurement != nil || showControl {Image(systemName:"plus").font(.title2.weight(.light)).foregroundStyle(.white).shadow(color:.black,radius:2).allowsHitTesting(false)}
            CaptureHUD {
                CaptureTool(symbol:"xmark",label:"Сохранить и закрыть камеру",id:"capture-close",busy:controller.savingMap){closeCapture()}.disabled(controller.savingMap)
                CaptureTool(symbol:controller.torchOn ? "flashlight.on.fill":"flashlight.off.fill",label:"Фонарик",id:"capture-torch",active:controller.torchOn){controller.toggleTorch()}
                CaptureTool(symbol:"square.3.layers.3d",label:"Покрытие LiDAR",id:"capture-coverage",active:controller.coverageVisible){controller.toggleCoverage()}
                CaptureTool(symbol:"questionmark",label:"Инструменты и состояние съёмки",id:"capture-help"){showHelp=true}
            } right: {
                if onMeasurement != nil {
                    CaptureTool(symbol:"plus",label:"Добавить угол контура",id:"capture-corner"){controller.addMeasurementCorner()}
                    CaptureTool(symbol:"arrow.uturn.backward",label:"Убрать последний угол",id:"capture-undo"){controller.undoMeasurementCorner()}.disabled(controller.measurementPoints.isEmpty)
                    CaptureTool(symbol:"checkmark",label:"Применить контур",id:"capture-apply"){applyMeasurement()}.disabled(controller.measurementPoints.count<3)
                } else {
                    CaptureTool(symbol:controller.recording ? "pause.fill":"play.fill",label:controller.recording ? "Приостановить запись":"Продолжить запись",id:"capture-pause",active:controller.recording){controller.toggle()}.disabled(controller.savingMap)
                    CaptureTool(symbol:"square.and.arrow.down",label:"Сохранить текущий сектор",id:"capture-save-sector"){controller.saveSector()}.disabled(controller.savingMap)
                    CaptureTool(symbol:"scope",label:"Отметить опорную точку в центре",id:"capture-anchor"){controlName="";showControl=true}
                }
                CaptureTool(symbol:"x0",label:"Помощник x0",id:"capture-assistant"){if controller.recording{controller.toggle()};showAssistant=true}
            }
        }.statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear{controller.configure(store:store,project:project)}
        .onDisappear{controller.finish()}
        .onChange(of:phase){_,value in if value != .active{controller.finish()}else if !controller.savingMap && !closeRequested{controller.start()}}
        .onChange(of:controller.savingMap){_,saving in if !saving{if closeRequested && !controller.hasUnsavedPoints{dismiss()}else if phase == .active && !closeRequested{controller.start()}}}
        .sheet(isPresented:$showHelp){NavigationStack{List{
            Section("Сейчас"){Text(controller.status);LabeledContent("Сохранено частей",value:"\(controller.savedChunks)");LabeledContent("Точек глубины",value:"\(controller.pointCount)");if onMeasurement != nil{Text("Углов: \(controller.measurementPoints.count) · \(controller.measuredArea,specifier:"%.2f") м²")}}
            Section("Кнопки по краям"){
                Label("Фонарик — включить или выключить свет",systemImage:"flashlight.on.fill")
                Label("Слои — показать измеренные поверхности. Зелёная заливка появляется по данным LiDAR.",systemImage:"square.3.layers.3d")
                if onMeasurement != nil{Label("Плюс — указать основания углов по порядку. Галочка — применить контур.",systemImage:"plus")}
                else{Label("Пауза останавливает запись; камера остаётся открытой.",systemImage:"pause.fill");Label("Стрелка вниз сохраняет текущую часть. Следующий участок снимайте с перекрытием.",systemImage:"square.and.arrow.down");Label("Прицел — опорная точка для совмещения.",systemImage:"scope")}
                Label("Крестик сохраняет работу и возвращает на карту.",systemImage:"xmark")
                Text("x0 — вопрос помощнику. Запись приостанавливается; продолжите её кнопкой ▶ после возвращения.")
            }
            if controller.canReset{Section("Привязка"){Button("Начать с новой привязкой"){controller.start(fresh:true);showHelp=false}}}
        }.navigationTitle("Съёмка").toolbar{Button("К камере"){showHelp=false}}}}
        .sheet(isPresented:$showAssistant){FieldAssistantView(project:project,context:"Съёмка с LiDAR. \(controller.status). Частей: \(controller.savedChunks).")}
        .alert("Опорная точка",isPresented:$showControl){TextField("Например, A-01",text:$controlName);Button("Сохранить"){let name=controlName.trimmingCharacters(in:.whitespacesAndNewlines);if !name.isEmpty{controller.markControl(name:name,screenPoint:CGPoint(x:controller.view.bounds.midX,y:controller.view.bounds.midY))}};Button("Отмена",role:.cancel){}}message:{Text("Наведите центр на устойчивую точку. Повторяйте это имя только для того же места.")}
        .alert("Съёмка",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){Button("Понятно"){controller.error=nil}}message:{Text(controller.error ?? "")}
    }
    private func applyMeasurement(){guard let onMeasurement else{return};let points=controller.measurementPoints;guard Geometry.validPolygon(points.map{[$0[0],$0[1]]}) else{controller.error="Контур пересекается или содержит слишком мало углов";return};onMeasurement(points,controller.measuredArea,controller.currentFrameId);closeCapture()}
    private func closeCapture(){closeRequested=true;controller.finish();if controller.hasUnsavedPoints{closeRequested=false}else if !controller.savingMap{dismiss()}}
}
