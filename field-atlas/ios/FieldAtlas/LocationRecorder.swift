import Foundation
import CoreLocation
import FieldCore

struct TrackSnapshot:Codable {var kind:String;var points:[[Double]];var segments:[[[Double]]];var needsReview:Bool;var manual:Bool?=nil;var origin:GeoOrigin?=nil}

@MainActor final class LocationRecorder: NSObject,ObservableObject,CLLocationManagerDelegate {
    @Published var position: [Double]?; @Published var positionTime:Date?; @Published var accuracy: Double?; @Published var message="Положение не определено"
    @Published var points: [[Double]]=[]; @Published var segments: [[[Double]]]=[]
    @Published var recording=false; @Published var paused=false; @Published var needsReview=false
    @Published var manual=false
    @Published private(set) var geographicPosition:GeoOrigin?
    @Published private(set) var authorization:CLAuthorizationStatus = .notDetermined
    @Published private(set) var reducedAccuracy=false
    @Published private(set) var locating=false
    var trackChanged:(()->Void)?
    var origin: GeoOrigin?;var originChanged: ((GeoOrigin)->Void)?
    private let manager=CLLocationManager();private var last: CLLocation?;private var breakNext=false
    override init(){super.init();manager.delegate=self;manager.desiredAccuracy=kCLLocationAccuracyBest;manager.distanceFilter=0.7;authorization=manager.authorizationStatus}
    func locate(){
        #if DEBUG
        if ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"] != nil {
            if let value=ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_LOCATION"] {
                let parts=value.split(separator:",").compactMap{Double($0)}
                if parts.count==3{authorization = .authorizedWhenInUse;receive(CLLocation(coordinate:CLLocationCoordinate2D(latitude:parts[0],longitude:parts[1]),altitude:0,horizontalAccuracy:parts[2],verticalAccuracy:100,timestamp:Date()))}
            }
            return
        }
        #endif
        authorization=manager.authorizationStatus;reducedAccuracy=manager.accuracyAuthorization == .reducedAccuracy
        switch authorization {
        case .notDetermined:locating=true;message="Разрешите определение положения";manager.requestWhenInUseAuthorization()
        case .authorizedAlways,.authorizedWhenInUse:locating=true;message="Ищем GPS…";manager.startUpdatingLocation()
        case .denied:locating=false;message="GPS запрещён · откройте настройки"
        case .restricted:locating=false;message="Геолокация ограничена устройством"
        @unknown default:locating=false;message="Геолокация недоступна"
        }
    }
    func requestPrecise(){manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey:"FieldSurvey"){[weak self] _ in Task{@MainActor in self?.locate()}}}
    var visiblePosition:GeoOrigin?{guard let time=positionTime,Date().timeIntervalSince(time)<60,let accuracy,accuracy>=0,accuracy<=10000 else{return nil};return geographicPosition}
    var canOpenSettings:Bool{authorization == .denied || authorization == .restricted}
    func restore(_ snapshot:TrackSnapshot){if let savedOrigin=snapshot.origin{origin=savedOrigin};points=snapshot.points;segments=snapshot.segments;needsReview=snapshot.needsReview;manual=snapshot.manual ?? false;paused = !manual;recording=true;breakNext=true;last=nil;message=manual ? "Ручной контур восстановлен · добавляйте точки на плане":"Сохранённый обход · продолжите запись"}
    func begin(manual:Bool=false){self.manual=manual;breakNext=false;points=[];segments=[[]];last=nil;needsReview=manual;recording=true;paused=false;if manual{message="Касайтесь плана, добавляя углы по порядку"}else{locate()}}
    func addManual(_ point:[Double]){guard manual,recording,point.count==2,point.allSatisfy(\.isFinite) else{return};if let last=points.last,hypot(last[0]-point[0],last[1]-point[1])<0.05{return};points.append(point);segments=[points];trackChanged?()}
    func pause(){paused.toggle();if !paused{breakNext=true;needsReview=true;locate()};trackChanged?()}
    var freshPosition:[Double]?{guard let time=positionTime,Date().timeIntervalSince(time)<30,let accuracy,accuracy<=20 else{return nil};return position}
    func undo(){
        guard !points.isEmpty else{return};points.removeLast()
        while let tail=segments.last,tail.isEmpty{segments.removeLast()}
        if !segments.isEmpty{segments[segments.count-1].removeLast()}
        last=nil;trackChanged?()
    }
    func stop(){recording=false}
    func stopLocation(){locating=false;manager.stopUpdatingLocation()}
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager){
        authorization=manager.authorizationStatus;reducedAccuracy=manager.accuracyAuthorization == .reducedAccuracy
        if authorization == .denied || authorization == .restricted{position=nil;geographicPosition=nil;positionTime=nil;locating=false;message="GPS запрещён · откройте настройки"}
        else if locating && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse){manager.startUpdatingLocation();message="Ищем GPS…"}
    }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: Error){message="Координаты недоступны; запись сохранена"}
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]){
        guard let value=locations.last else{return};receive(value)
    }
    func receive(_ value:CLLocation){
        guard value.horizontalAccuracy>=0,abs(value.timestamp.timeIntervalSinceNow)<10,CLLocationCoordinate2DIsValid(value.coordinate) else{return}
        accuracy=value.horizontalAccuracy;positionTime=value.timestamp;geographicPosition=GeoOrigin(lat:value.coordinate.latitude,lon:value.coordinate.longitude)
        message=value.horizontalAccuracy>20 ? "Примерно ±\(Int(value.horizontalAccuracy)) м · ждём точнее":"GPS ±\(Int(value.horizontalAccuracy)) м"
        if origin == nil && recording && manual && !points.isEmpty {message="Локальный контур не привязан к GPS";return}
        if origin == nil && value.horizontalAccuracy<=20 {origin=GeoOrigin(lat:value.coordinate.latitude,lon:value.coordinate.longitude);originChanged?(origin!)}
        guard let origin else{return};position=Geometry.local(lat:value.coordinate.latitude,lon:value.coordinate.longitude,origin:origin)
        guard recording,!manual,!paused,let position else{return}
        guard value.horizontalAccuracy<=12 else{needsReview=true;breakNext=true;trackChanged?();return}
        if let previous=last,!breakNext {
            let dt=value.timestamp.timeIntervalSince(previous.timestamp)
            if dt<=0{return}
            if value.distance(from:previous)/dt>6{needsReview=true;breakNext=true;message="Скачок GPS отклонён";last=value;trackChanged?();return}
            if value.distance(from:previous)<0.7{return}
        }
        if breakNext{segments.append([]);breakNext=false}
        if segments.isEmpty{segments=[[]]};segments[segments.count-1].append(position);points.append(position);last=value;trackChanged?()
    }
}
