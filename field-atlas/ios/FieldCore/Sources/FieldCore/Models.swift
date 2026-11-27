import Foundation

public enum ProjectKind: String, Codable, CaseIterable, Identifiable {
    case interior, exterior, land, cemetery
    public var id: String { rawValue }
    public var title: String { switch self { case .interior: return "Внутри помещения"; case .exterior: return "Здание снаружи"; case .land: return "Участок"; case .cemetery: return "Кладбище" } }
    public var subtitle: String { switch self { case .interior: return "Комнаты, проёмы и предметы"; case .exterior: return "Фасады, входы и детали"; case .land: return "Границы, дорожки и деревья"; case .cemetery: return "Захоронения и надписи" } }
    public var symbol: String { switch self { case .interior: return "square.split.2x2"; case .exterior: return "building.2"; case .land: return "leaf"; case .cemetery: return "map" } }
    public var objectKind: String { switch self { case .interior: return "room"; case .exterior: return "facade"; case .land: return "object"; case .cemetery: return "grave" } }
    public var objectTitle: String { self == .cemetery ? "Захоронение" : self == .interior ? "Помещение" : "Объект" }
    public var outdoor: Bool { self != .interior }
}
public struct GeoOrigin: Codable, Equatable { public var lat: Double; public var lon: Double; public init(lat: Double, lon: Double) { self.lat=lat; self.lon=lon } }
public struct FieldProject: Codable, Identifiable, Equatable {
    public var siteID:String?
    public var id: String; public var type: ProjectKind; public var title: String; public var createdAt: Double; public var synthetic: Bool
    public init(title: String, type: ProjectKind) { id=UUID().uuidString; self.title=title; self.type=type; createdAt=Date().timeIntervalSince1970*1000; synthetic=false }
}
public struct PersonReading: Codable, Identifiable, Equatable {
    public var id=UUID().uuidString; public var name=""; public var birth=""; public var death=""
    public var relation:String?;public var datesText:String?;public var evidence:[NameReadingEvidence]?;public var needsReview:Bool?
    public init() {}
}
public struct PhotoAttachment: Codable, Identifiable, Equatable {
    public var id: String; public var role: String; public var sha256: String; public var name: String
    public init(id: String, role: String, sha256: String, name: String) { self.id=id; self.role=role; self.sha256=sha256; self.name=name }
}
public struct Observation: Codable, Identifiable, Equatable {
    public var id=UUID().uuidString; public var projectId: String; public var kind: String
    public var title=""; public var locationAccuracy:Double?; public var locationMethod:String?; public var point: [Double]?; public var points: [[Double]]=[]
    public var segments: [[[Double]]]=[]; public var photos: [PhotoAttachment]=[]; public var persons: [PersonReading]=[]
    public var transcription=""; public var comments=""; public var status="draft"; public var noInscription=false; public var unreadable=false
    public var measureLength: Double?; public var measureWidth: Double?; public var measureMethod="none"
    public var measuredArea:Double?;public var footprint:[[Double]]=[];public var measurementFrameId:String?
    public var roomPlan:RoomPlanDocument?;public var roomPlanSourceId:String?;public var roomPlanAssetId:String?;public var roomPlanStructureId:String?;public var roomPlanModelId:String?
    public var fieldMissionID:String?;public var sourceAssetIDs:[String]?
    public var needsReview=false; public var origin: GeoOrigin?; public var serverVersion=0; public var localRevision=0; public var dirty=true
    public var entityID:String?;public var parentEntityID:String?;public var localNumber:String?
    public var burialKind:String?;public var totalMinimum:Int?;public var totalMaximum:Int?;public var unidentifiedCount:Int?;public var countSource:String?
    public var createdAt=Date().timeIntervalSince1970*1000
    public init(projectId: String, kind: String) { self.projectId=projectId; self.kind=kind }
    public var missing: [String] {
        var value: [String]=[]
        if point == nil { value.append("Место объекта") }
        if !photos.contains(where: {$0.role=="overview"}) { value.append("Общий вид") }
        if kind=="grave" {
            if !noInscription && !photos.contains(where: {$0.role=="inscription"}) { value.append("Фото плиты") }
            if transcription.isEmpty && !unreadable && !noInscription { value.append("Чтение надписи") }
        }
        return value
    }
}
public struct ScanChunk: Codable, Identifiable {
    public var schema="field-scan-v1"; public var id=UUID().uuidString; public var frameId: String
    public var tracking="normal"; public var points: [[Double]]; public var anchors: [String:[Double]]; public var sourceFrameIds: [String]=[]
    public init(frameId: String, points: [[Double]], anchors: [String:[Double]]=[:]) { self.frameId=frameId; self.points=points; self.anchors=anchors }
}
public struct ScanReference: Codable, Identifiable {
    public var id: String; public var projectId: String; public var assetId: String; public var frameId: String; public var pointCount: Int; public var createdAt: Double
    public init(chunk: ScanChunk, projectId: String, assetId: String) { id=chunk.id; self.projectId=projectId; self.assetId=assetId; frameId=chunk.frameId; pointCount=chunk.points.count; createdAt=Date().timeIntervalSince1970 }
}
public struct CoverageCell: Codable, Hashable {
    public var x: Double; public var y: Double; public var z: Double; public var quality: Int; public var cell: Double
}
public enum Geometry {
    public static func area(_ points: [[Double]]) -> Double {
        guard points.count>=3,points.allSatisfy({$0.count>=2 && $0.allSatisfy(\.isFinite)}) else { return 0 }
        return abs(points.indices.reduce(0.0) { result,i in let j=(i+1)%points.count; return result+points[i][0]*points[j][1]-points[j][0]*points[i][1] })/2
    }
    public static func local(lat: Double, lon: Double, origin: GeoOrigin) -> [Double] { [(lon-origin.lon)*111320*cos(origin.lat * .pi/180),(lat-origin.lat)*111320] }
    public static func coverage(_ points: [[Double]], cell: Double=0.5) -> [CoverageCell] {
        guard cell>0 else { return [] }; var result: [String:CoverageCell]=[:]
        for p in points where p.count==4 && p.allSatisfy(\.isFinite) && p[3]>=1 {
            let x=floor(p[0]/cell)*cell,y=floor(p[1]/cell)*cell,z=floor(p[2]/cell)*cell; let key="\(x):\(y):\(z)"
            result[key]=CoverageCell(x:x,y:y,z:z,quality:max(Int(p[3]),result[key]?.quality ?? 0),cell:cell)
        }
        return Array(result.values)
    }
    public static func validPolygon(_ p: [[Double]]) -> Bool {
        guard p.count>=3,p.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}),area(p)>0.1 else{return false}
        func cross(_ a:[Double],_ b:[Double],_ c:[Double])->Double{(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])}
        for i in p.indices {
            let n=(i+1)%p.count
            if hypot(p[i][0]-p[n][0],p[i][1]-p[n][1])<0.05{return false}
            for j in (i+1)..<p.count where j != n && !(i==0 && j==p.count-1) {
                let k=(j+1)%p.count
                let boxesOverlap=max(min(p[i][0],p[n][0]),min(p[j][0],p[k][0]))<=min(max(p[i][0],p[n][0]),max(p[j][0],p[k][0])) && max(min(p[i][1],p[n][1]),min(p[j][1],p[k][1]))<=min(max(p[i][1],p[n][1]),max(p[j][1],p[k][1]))
                if boxesOverlap && cross(p[i],p[n],p[j])*cross(p[i],p[n],p[k])<=0 && cross(p[j],p[k],p[i])*cross(p[j],p[k],p[n])<=0{return false}
            }
        }
        return true
    }
}
