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
    var body:some View{
        ZStack{
            Color.black.ignoresSafeArea()
            if controller.supportsLiDAR{CaptureCamera(controller:controller).ignoresSafeArea()}
            else{ContentUnavailableView("LiDAR недоступен",systemImage:"viewfinder",description:Text("Откройте съёмку на совместимом iPhone или iPad. Карта и карточки работают независимо." )).foregroundStyle(.white)}
            Image(systemName:"plus").font(.title2.weight(.light)).foregroundStyle(.white).shadow(color:.black,radius:2)
            VStack{
                HStack(alignment:.top){
                    VStack(alignment:.leading,spacing:5){Text(project.title).font(.caption);Text(onMeasurement == nil ? "Съёмка участка":"Контур участка").font(.headline)}
                    Spacer()
                    Button{controller.toggleTorch()}label:{Image(systemName:controller.torchOn ? "flashlight.on.fill":"flashlight.off.fill").frame(width:44,height:44).background(.black.opacity(0.5),in:Circle()).foregroundStyle(controller.torchOn ? .yellow:.white)}
                        .accessibilityLabel(controller.torchOn ? "Выключить фонарь":"Включить фонарь").accessibilityIdentifier("capture-torch")
                    Button{closeCapture()}label:{Image(systemName:"xmark").frame(width:44,height:44).background(.black.opacity(0.5),in:Circle())}.accessibilityLabel("Завершить и вернуться")
                }.padding(16)
                HStack{Text(controller.status).font(.caption).padding(10).background(.black.opacity(0.6),in:RoundedRectangle(cornerRadius:12));Spacer()}.padding(.horizontal,16)
                if controller.canReset{Button("Начать новую привязку"){controller.start(fresh:true)}.buttonStyle(.borderedProminent).tint(.orange)}
                Spacer()
                if controller.savingMap{ProgressView("Сохраняем привязку…").tint(.white)}
                if onMeasurement != nil{Button("Убрать последний угол"){controller.undoMeasurementCorner()}.disabled(controller.measurementPoints.isEmpty);Text("\(controller.measurementPoints.count) углов · \(controller.measuredArea,specifier:"%.2f") м²").font(.title3.monospacedDigit()).padding(12).background(.black.opacity(0.6),in:Capsule())}
                VStack(spacing:14){
                    HStack(spacing:16){Label("Измерено",systemImage:"square.fill").foregroundStyle(.green);Label("Уточнить",systemImage:"square.dashed").foregroundStyle(.yellow);Spacer()}.font(.caption)
                    HStack(spacing:12){
                        if let onMeasurement{
                            Button("Добавить угол"){controller.addMeasurementCorner()}.buttonStyle(.borderedProminent)
                            Button("Применить"){
                                let points=controller.measurementPoints
                                guard Geometry.validPolygon(points.map{[$0[0],$0[1]]}) else{controller.error="Контур пересекается или содержит слишком мало углов";return}
                                onMeasurement(points,controller.measuredArea,controller.currentFrameId);closeCapture()
                            }.buttonStyle(.bordered).disabled(controller.measurementPoints.count<3)
                        }else{
                            Button{controller.toggle()}label:{Label(controller.recording ? "Пауза":"Продолжить",systemImage:controller.recording ? "pause.fill":"play.fill")}.buttonStyle(.borderedProminent)
                            Button("Ориентир"){controlName="";showControl=true}.buttonStyle(.bordered)
                            Button("Готово"){closeCapture()}.buttonStyle(.bordered)
                        }
                    }.controlSize(.large).disabled(!controller.supportsLiDAR || controller.savingMap)
                    Text(onMeasurement == nil ? "Части сохраняются на устройстве. Передача выполняется отдельно.":"Наводите центр на основания углов по порядку. AR-площадь требует контрольного промера.").font(.caption2).foregroundStyle(.white.opacity(0.8)).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(16).background(.black.opacity(0.7),in:RoundedRectangle(cornerRadius:20)).padding(12)
            }.foregroundStyle(.white)
        }
        .onAppear{controller.configure(store:store,project:project)}
        .onDisappear{controller.finish()}
        .onChange(of:phase){_,value in if value != .active{controller.finish()}else if !controller.savingMap{controller.start()}}
        .onChange(of:controller.savingMap){_,saving in if !saving{if closeRequested && !controller.hasUnsavedPoints{dismiss()}else if phase == .active{controller.start()}}}
        .alert("Опорная точка",isPresented:$showControl){TextField("Например, A-01",text:$controlName);Button("Сохранить"){let name=controlName.trimmingCharacters(in:.whitespacesAndNewlines);if !name.isEmpty{controller.markControl(name:name,screenPoint:CGPoint(x:controller.view.bounds.midX,y:controller.view.bounds.midY))}};Button("Отмена",role:.cancel){}}message:{Text("Наведите центр на устойчивую точку. В другой съёмке используйте это имя только для того же места.")}
        .alert("Съёмка",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){Button("Понятно"){controller.error=nil}}message:{Text(controller.error ?? "")}
    }
    private func closeCapture(){
        closeRequested=true;controller.finish()
        if controller.hasUnsavedPoints{closeRequested=false}
        else if !controller.savingMap{dismiss()}
    }
}
