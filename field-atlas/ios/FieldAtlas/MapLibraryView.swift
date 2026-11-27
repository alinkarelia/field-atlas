import SwiftUI
import FieldCore

struct MapLibraryView:View {
    @EnvironmentObject var maps:MapPackageStore
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location=LocationRecorder()
    @State private var query=""
    @State private var preview:MapPackage?
    @State private var removing:MapPackage?
    @State private var showGPS=false
    var onSelect:((MapPackage)->Void)?=nil
    private var filtered:[MapPackage]{maps.packages.filter{$0.matches(query)}}
    var body:some View {
        NavigationStack{List{
            Section{
                HStack{Image(systemName:maps.networkAvailable ? "wifi":"wifi.slash");Text(maps.networkAvailable ? "Сеть доступна":"Без интернета");Spacer();Button{showGPS=true}label:{Image(systemName:"location")}.accessibilityLabel("Состояние GPS")}
                Text("Карты загружаются с Google Диска Al In через сайт проекта. Вход в Google не нужен. Скачанные карты работают без сети; ваши съёмки хранятся отдельно.").font(.footnote).foregroundStyle(.secondary)
            }
            if let point=location.visiblePosition,query.isEmpty {
                let nearby=maps.packages.filter{$0.contains(point)}.sorted{$0.area<$1.area}
                if !nearby.isEmpty{Section("Рядом с вами"){ForEach(nearby){package in packageRow(package)}}}
            }
            Section(query.isEmpty ? "Города и регионы":"Результаты"){
                ForEach(filtered){package in packageRow(package)}
                if filtered.isEmpty{ContentUnavailableView.search(text:query);Text("Новых территорий пока нет в каталоге. Обновите каталог; съёмки и ручные отметки доступны в любом месте.").font(.footnote)}
            }
            if !maps.message.isEmpty{Section{Text(maps.message).font(.footnote).accessibilityIdentifier("map-download-message")}}
            Section{
                Button{Task{await maps.refreshCatalog()}}label:{Label("Обновить каталог",systemImage:"arrow.clockwise")}.disabled(maps.busy)
                Text("© OpenStreetMap, ODbL · Protomaps. Пакеты содержат область покрытия с соседними участками; это не административные или кадастровые границы. Карта не включает расчёт автомобильных маршрутов.").font(.caption).foregroundStyle(.secondary)
            }
        }.searchable(text:$query,prompt:"Город или область").navigationTitle("Карты без интернета").navigationBarTitleDisplayMode(.inline)
            .toolbar{ToolbarItem(placement:.confirmationAction){Button("Готово"){dismiss()}}}
            .onAppear{maps.load(root:store.root);location.locate()}.onDisappear{location.stopLocation()}
            .sheet(item:$preview){package in MapPreviewView(package:package){maps.select(package);onSelect?(package);preview=nil;dismiss()}}
            .sheet(isPresented:$showGPS){GPSStatusView(location:location)}
            .confirmationDialog("Удалить скачанную карту?",isPresented:Binding(get:{removing != nil},set:{if !$0{removing=nil}}),titleVisibility:.visible){Button("Удалить подложку",role:.destructive){if let p=removing{maps.remove(p)};removing=nil}}message:{Text("Съёмки, фотографии и карточки останутся на устройстве.")}
        }
    }
    private func packageRow(_ p:MapPackage)->some View {
        VStack(alignment:.leading,spacing:10){
            HStack(alignment:.top){Image(systemName:maps.localURL(p) != nil ? "checkmark.circle.fill":"map").foregroundStyle(Palette.green).font(.title2);VStack(alignment:.leading,spacing:4){Text(p.title).font(.headline);Text(status(p)).font(.caption).foregroundStyle(.secondary)};Spacer()}
            Text(p.detail).font(.caption).foregroundStyle(.secondary)
            if maps.activeID==p.id{ProgressView(value:maps.progress);HStack{Text(bytes(maps.downloadedBytes)+" / "+bytes(p.bytes)).font(.caption.monospacedDigit());Spacer();Button("Пауза"){maps.pause()}.accessibilityIdentifier("map-pause-"+p.id)}}
            else{HStack{
                Button("Показать"){preview=p}.buttonStyle(.bordered).accessibilityIdentifier("map-preview-"+p.id)
                if !maps.isCurrent(p){Button(maps.partialBytes(p)>0 ? "Продолжить":"Скачать"){maps.start(p)}.buttonStyle(.borderedProminent).disabled(maps.busy || maps.checking.contains(p.id)).accessibilityIdentifier("map-download-"+p.id)}
                Spacer()
                if maps.installed[p.id] != nil{Button{removing=p}label:{Image(systemName:"trash")}.disabled(maps.busy).accessibilityLabel("Удалить карту "+p.title)}
            }}
        }.padding(.vertical,6).accessibilityElement(children:.contain).accessibilityIdentifier("map-package-"+p.id)
    }
    private func bytes(_ value:Int64)->String{ByteCountFormatter.string(fromByteCount:value,countStyle:.file)}
    private func status(_ p:MapPackage)->String{
        if maps.checking.contains(p.id){return "Проверяем сохранённую карту…"}
        if maps.isCurrent(p){return "Доступна без интернета · "+bytes(p.bytes)+" · "+p.dataDate}
        if maps.localURL(p) != nil{return "Есть сохранённая версия · доступно обновление"}
        let part=maps.partialBytes(p);return (part>0 ? "Сохранено "+bytes(part)+" из ":"")+bytes(p.bytes)+" · "+p.dataDate
    }
}

private struct MapPreviewView:View {
    @EnvironmentObject var maps:MapPackageStore
    @Environment(\.dismiss) private var dismiss
    let package:MapPackage;let select:()->Void
    var body:some View{NavigationStack{ZStack(alignment:.bottom){
        MapLibrePlan(records:[],origin:nil,basemapStyleURL:maps.styleURL,focus:package.center,focusBounds:package.bounds,onMapError:{maps.mapFailed()}).ignoresSafeArea(edges:.bottom)
        VStack(spacing:10){Text(maps.offlineReady && maps.activeMapName==package.title ? "Эта карта доступна без интернета":"Для подробной карты без сети нажмите «Скачать» в каталоге.").font(.footnote);Button("Открыть эту территорию",action:select).buttonStyle(.borderedProminent);Text("© OpenStreetMap · Protomaps").font(.caption2)}.padding().frame(maxWidth:.infinity).background(.regularMaterial)
    }.navigationTitle(package.title).navigationBarTitleDisplayMode(.inline).toolbar{Button("Назад"){dismiss()}}.onAppear{maps.select(package)}}}
}

struct GPSStatusView:View {
    @ObservedObject var location:LocationRecorder
    @Environment(\.dismiss) private var dismiss
    var body:some View{NavigationStack{Form{
        Section("Моё положение"){
            Text(location.message).accessibilityIdentifier("gps-status")
            if let p=location.visiblePosition{LabeledContent("Широта",value:String(format:"%.6f",p.lat));LabeledContent("Долгота",value:String(format:"%.6f",p.lon))}
            if let a=location.accuracy{LabeledContent("Погрешность",value:String(format:"± %.0f м",a))}
            Text("Приблизительное положение показывается на карте. Для записи обхода приложение принимает точки с погрешностью до 12 м; слабый сигнал оставляет разрыв, а не ложную линию.").font(.footnote).foregroundStyle(.secondary)
        }
        Section{
            Button("Найти меня снова"){location.locate()}
            if location.reducedAccuracy{Button("Разрешить точное положение"){location.requestPrecise()}}
            if location.canOpenSettings{Button("Открыть настройки приложения"){if let url=URL(string:UIApplication.openSettingsURLString){UIApplication.shared.open(url)}}}
            Text("Если GPS ещё не найден, можно выбрать место на карте вручную. Ручное положение будет отмечено как приблизительное.").font(.footnote)
        }
    }.navigationTitle("Геолокация").navigationBarTitleDisplayMode(.inline).toolbar{Button("Готово"){dismiss()}}}}
}
