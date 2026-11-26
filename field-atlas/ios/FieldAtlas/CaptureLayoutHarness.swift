#if DEBUG
import SwiftUI

/// Layout-only fixture; never creates fake scans, photos, GPS fixes or server requests.
struct CaptureLayoutHarness:View {
    @State private var light=false
    @State private var coverage=true
    @State private var recording=true
    @State private var help=false
    @State private var count=0
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CaptureHUD {
                CaptureTool(symbol:"xmark",label:"Закрыть",id:"capture-close"){count+=1}
                CaptureTool(symbol:light ? "flashlight.on.fill":"flashlight.off.fill",label:"Фонарик",id:"capture-torch",active:light){light.toggle()}
                CaptureTool(symbol:"square.3.layers.3d",label:"Покрытие",id:"capture-coverage",active:coverage){coverage.toggle()}
                CaptureTool(symbol:"questionmark",label:"Инструменты",id:"capture-help"){help=true}
            } right: {
                CaptureTool(symbol:recording ? "pause.fill":"play.fill",label:"Запись",id:"capture-pause",active:recording){recording.toggle()}
                CaptureTool(symbol:"ruler",label:"Размер",id:"room-measure"){count+=1}
                CaptureTool(symbol:"camera.fill",label:"Фото",id:"room-photo"){count+=1}
                CaptureTool(symbol:"ellipsis",label:"Ещё",id:"room-more"){count+=1}
                CaptureTool(symbol:"x0",label:"Помощник x0",id:"capture-assistant"){count+=1}
            }
        }.accessibilityIdentifier("layout-fixture").statusBarHidden(true).persistentSystemOverlays(.hidden)
            .sheet(isPresented:$help){CaptureHelp(title:"Проверка интерфейса",status:"Это проверка расположения кнопок без камеры и LiDAR.",items:[])}
    }
}
#endif
