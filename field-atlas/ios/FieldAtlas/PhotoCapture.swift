import SwiftUI
import AVFoundation

@MainActor final class PhotoCaptureController:NSObject,ObservableObject,AVCapturePhotoCaptureDelegate {
    let session=AVCaptureSession()
    let preview=PhotoPreviewView(frame:.zero)
    private let output=AVCapturePhotoOutput()
    private let queue=DispatchQueue(label:"ru.archiverf.photo-camera")
    private var configured=false
    private var starting=false
    private var desiredRunning=false
    private var rotation:AVCaptureDevice.RotationCoordinator?
    private var observation:NSKeyValueObservation?
    @Published var ready=false
    @Published var busy=false
    @Published var torchOn=false
    @Published var photo:Data?
    @Published var error:String?
    override init(){super.init();preview.videoLayer.session=session}
    func start()async {
        desiredRunning=true
        guard !starting else{return};starting=true;defer{starting=false}
        #if DEBUG
        if fixtureEnabled{ready=true;return}
        #endif
        if AVCaptureDevice.authorizationStatus(for:.video) == .notDetermined{_ = await AVCaptureDevice.requestAccess(for:.video)}
        guard desiredRunning else{return}
        guard AVCaptureDevice.authorizationStatus(for:.video) == .authorized else{error="Разрешите камеру в настройках приложения.";return}
        if configured{let session=session;queue.async{session.startRunning()};ready=true;return}
        guard let device=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else{error="Камера на этом устройстве недоступна. Можно выбрать снимок из фототеки в карточке.";return}
        do {
            let input=try AVCaptureDeviceInput(device:device),session=session,output=output
            let success=await withCheckedContinuation{continuation in queue.async{
                session.beginConfiguration();session.sessionPreset = .photo
                guard session.canAddInput(input),session.canAddOutput(output) else{session.commitConfiguration();continuation.resume(returning:false);return}
                session.addInput(input);session.addOutput(output);output.maxPhotoQualityPrioritization = .quality
                session.commitConfiguration();continuation.resume(returning:true)
            }}
            guard success else{error="Не удалось открыть фотокамеру";return}
            configured=true
            let coordinator=AVCaptureDevice.RotationCoordinator(device:device,previewLayer:preview.videoLayer);rotation=coordinator
            observation=coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,options:[.initial,.new]){[weak self] c,_ in
                let angle=c.videoRotationAngleForHorizonLevelPreview
                Task{@MainActor in if let connection=self?.preview.videoLayer.connection,connection.isVideoRotationAngleSupported(angle){connection.videoRotationAngle=angle}}
            }
            guard desiredRunning else{return}
            queue.async{session.startRunning()};ready=true
        }catch{self.error=error.localizedDescription}
    }
    func stop(){desiredRunning=false;ready=false;do{try CaptureLight.turnOff();torchOn=false}catch{self.error=error.localizedDescription};let session=session;queue.async{session.stopRunning()}}
    func toggleTorch(){do{torchOn=try CaptureLight.toggle()}catch{self.error=error.localizedDescription}}
    func focus(_ point:CGPoint){
        guard let device=rotation?.device else{return}
        let p=preview.videoLayer.captureDevicePointConverted(fromLayerPoint:point)
        do{try device.lockForConfiguration();defer{device.unlockForConfiguration()};if device.isFocusPointOfInterestSupported{device.focusPointOfInterest=p;if device.isFocusModeSupported(.autoFocus){device.focusMode = .autoFocus}};if device.isExposurePointOfInterestSupported{device.exposurePointOfInterest=p;if device.isExposureModeSupported(.continuousAutoExposure){device.exposureMode = .continuousAutoExposure}}}catch{self.error=error.localizedDescription}
    }
    func capture(){
        guard ready,!busy,photo==nil else{return};busy=true
        #if DEBUG
        if fixtureEnabled{receive(data:Self.fixtureJPEG(),message:nil);return}
        #endif
        guard session.isRunning,output.connection(with:.video)?.isActive == true else{busy=false;error="Камера ещё готовится. Повторите снимок через секунду.";return}
        let angle=rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        if let connection=output.connection(with:.video),connection.isVideoRotationAngleSupported(angle){connection.videoRotationAngle=angle}
        let settings=AVCapturePhotoSettings(format:[AVVideoCodecKey:AVVideoCodecType.jpeg]);settings.photoQualityPrioritization = .quality;settings.flashMode = .off
        output.capturePhoto(with:settings,delegate:self)
    }
    nonisolated func photoOutput(_ output:AVCapturePhotoOutput,didFinishProcessingPhoto photo:AVCapturePhoto,error:Error?){
        let data=photo.fileDataRepresentation(),message=error?.localizedDescription
        Task{@MainActor [weak self] in self?.receive(data:data,message:message)}
    }
    private func receive(data:Data?,message:String?){busy=false;if let message{error=message}else if let data,UIImage(data:data) != nil{photo=data;stop();UIImpactFeedbackGenerator(style:.light).impactOccurred()}else{error="Фотография не получена. Повторите снимок."}}
    #if DEBUG
    private var fixtureEnabled:Bool{ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_PHOTO"] == "1" && UUID(uuidString:ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"] ?? "") != nil}
    private static func fixtureJPEG()->Data?{UIGraphicsImageRenderer(size:CGSize(width:720,height:960)).image{c in UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:720,height:960));("ТЕСТОВЫЙ СНИМОК\n18?4\nБез камеры и LiDAR" as NSString).draw(in:CGRect(x:60,y:220,width:600,height:400),withAttributes:[.font:UIFont.systemFont(ofSize:42),.foregroundColor:UIColor.black])}.jpegData(compressionQuality:0.95)}
    #endif
}

final class PhotoPreviewView:UIView {
    override class var layerClass:AnyClass{AVCaptureVideoPreviewLayer.self}
    var videoLayer:AVCaptureVideoPreviewLayer{layer as! AVCaptureVideoPreviewLayer}
    override init(frame:CGRect){super.init(frame:frame);videoLayer.videoGravity = .resizeAspectFill}
    required init?(coder:NSCoder){super.init(coder:coder);videoLayer.videoGravity = .resizeAspectFill}
}
private struct PhotoPreview:UIViewRepresentable {
    let controller:PhotoCaptureController
    func makeUIView(context:Context)->PhotoPreviewView{controller.preview}
    func updateUIView(_ view:PhotoPreviewView,context:Context){}
}

struct PhotoCaptureScreen:View {
    @Environment(\.scenePhase) private var phase
    @StateObject private var controller=PhotoCaptureController()
    @State private var showHelp=false
    let title:String
    let onCancel:()->Void
    let onSave:(Data)throws->Void
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let data=controller.photo,let image=UIImage(data:data){Image(uiImage:image).resizable().scaledToFit().ignoresSafeArea()}
            else{PhotoPreview(controller:controller).ignoresSafeArea().simultaneousGesture(SpatialTapGesture().onEnded{value in controller.focus(value.location)})}
            CaptureHUD {
                CaptureTool(symbol:"xmark",label:"Вернуться без фотографии",id:"photo-close"){onCancel()}.disabled(controller.busy)
                if controller.photo==nil{CaptureTool(symbol:controller.torchOn ? "flashlight.on.fill":"flashlight.off.fill",label:"Фонарик",id:"capture-torch",active:controller.torchOn){controller.toggleTorch()}.disabled(!controller.ready)}
                CaptureTool(symbol:"questionmark",label:"Как снять: "+title,id:"photo-help"){showHelp=true}
            } right: {
                if let data=controller.photo {
                    CaptureTool(symbol:"checkmark",label:"Сохранить фотографию: "+title,id:"photo-use"){do{try onSave(data)}catch{controller.error=error.localizedDescription}}
                    CaptureTool(symbol:"arrow.clockwise",label:"Переснять",id:"photo-retake"){controller.photo=nil;Task{await controller.start()}}
                } else {
                    CaptureTool(symbol:"circle.inset.filled",label:"Сделать фотографию: "+title,id:"photo-shutter",busy:controller.busy){controller.capture()}.disabled(!controller.ready || controller.busy)
                }
            }
        }.statusBarHidden(true).persistentSystemOverlays(.hidden).task{await controller.start()}.onDisappear{controller.stop()}
        .onChange(of:phase){_,p in if p != .active{controller.stop()}else if controller.photo==nil{Task{await controller.start()}}}
        .onReceive(NotificationCenter.default.publisher(for:AVCaptureSession.wasInterruptedNotification,object:controller.session)){_ in controller.ready=false;controller.error="Камера временно занята. Вернитесь к съёмке после завершения звонка или другой работы с камерой."}
        .onReceive(NotificationCenter.default.publisher(for:AVCaptureSession.interruptionEndedNotification,object:controller.session)){_ in if phase == .active && controller.photo==nil{Task{await controller.start()}}}
        .sheet(isPresented:$showHelp){CaptureHelp(title:title,status:controller.photo==nil ? "Коснитесь нужной детали для фокусировки. Нажмите круглую кнопку справа. После снимка: галочка — сохранить, стрелка — переснять.":"Проверьте резкость снимка. Галочка сохранит его в текущую карточку.",items:[("camera.fill","Общий вид","Включите памятник и границы захоронения целиком."),("text.viewfinder","Плита или табличка","Снимите прямо, затем при необходимости добавьте другой ракурс и боковое освещение. Ничем не закрашивайте надпись."),("person.crop.square","Портрет","Отдельный крупный снимок фотографии человека на памятнике."),("flashlight.on.fill","Фонарик","Нажмите слева. Если появляются блики, выключите или измените угол съёмки.")])}
        .alert("Фотография",isPresented:Binding(get:{controller.error != nil},set:{if !$0{controller.error=nil}})){Button("Понятно"){controller.error=nil};if AVCaptureDevice.authorizationStatus(for:.video) == .denied{Button("Настройки"){if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}}}}message:{Text(controller.error ?? "")}
    }
}
