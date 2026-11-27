import Foundation

public struct MapPackage:Codable,Identifiable,Equatable {
    public let id:String
    public let title:String
    public let parentID:String?
    public let revision:String
    public let dataDate:String
    /// [west,south,east,north], WGS84. Download extent, not a cadastral boundary.
    public let bounds:[Double]
    public let bytes:Int64
    public let sha256:String
    public let url:String
    public let maxZoom:Int
    public let detail:String
    public let bundledResource:String?
    public var center:GeoOrigin{GeoOrigin(lat:(bounds[1]+bounds[3])/2,lon:(bounds[0]+bounds[2])/2)}
    public var area:Double{(bounds[2]-bounds[0])*(bounds[3]-bounds[1])}
    public func contains(_ p:GeoOrigin)->Bool{p.lon>=bounds[0] && p.lon<=bounds[2] && p.lat>=bounds[1] && p.lat<=bounds[3]}
    public func matches(_ query:String)->Bool{let q=query.trimmingCharacters(in:.whitespacesAndNewlines);return q.isEmpty || (title+" "+detail).localizedCaseInsensitiveContains(q)}
    public func validated()throws->Self{
        guard id.range(of:"^[a-z0-9_-]{1,80}$",options:.regularExpression) != nil,
              revision.range(of:"^[a-zA-Z0-9._-]{1,80}$",options:.regularExpression) != nil,
              !title.isEmpty,title.count<=200,detail.count<=2000,bounds.count==4,bounds.allSatisfy(\.isFinite),
              bounds[0]>=(-180),bounds[2]<=180,bounds[1]>=(-85),bounds[3]<=85,bounds[0]<bounds[2],bounds[1]<bounds[3],
              (127...4_000_000_000).contains(bytes),(0...16).contains(maxZoom),
              sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
              let u=URL(string:url),u.scheme=="https",u.host=="archiverf.ru",u.user==nil,u.password==nil,u.port==nil,u.query==nil,u.fragment==nil,
              u.path=="/api/maps/files/"+sha256+".pmtiles",
              bundledResource.map({$0.range(of:"^[a-z0-9_-]{1,80}$",options:.regularExpression) != nil}) ?? true else{throw MapPackageError.invalidCatalog}
        return self
    }
}
public struct MapPackageCatalog:Codable {
    public let schemaVersion:Int
    public let revision:String
    public let packages:[MapPackage]
    public func validated()throws->Self{
        guard schemaVersion==1,!revision.isEmpty,revision.count<=80,packages.count<=2000,Set(packages.map(\.id)).count==packages.count else{throw MapPackageError.invalidCatalog}
        for p in packages{_ = try p.validated();if let parent=p.parentID{guard parent != p.id,packages.contains(where:{$0.id==parent})else{throw MapPackageError.invalidCatalog}}}
        return self
    }
}
public enum MapPackageError:LocalizedError {
    case invalidCatalog,invalidRange,damagedFile,noSpace
    public var errorDescription:String?{switch self{
    case .invalidCatalog:return "Не удалось проверить каталог карт. Сохранённые карты доступны."
    case .invalidRange:return "Сервер не подтвердил часть файла. Загрузка приостановлена."
    case .damagedFile:return "Файл карты не прошёл проверку. Предыдущая версия сохранена."
    case .noSpace:return "Недостаточно места. Освободите память или выберите меньшую территорию."
    }}
}
public enum MapDownloadPolicy {
    public static let chunkSize:Int64=2*1024*1024
    public static func range(offset:Int64,total:Int64)throws->ClosedRange<Int64>{
        guard offset>=0,total>=127,offset<total else{throw MapPackageError.invalidRange}
        return offset...min(total-1,offset+chunkSize-1)
    }
    public static func validateResponse(status:Int,contentRange:String?,bytes:Int64,range:ClosedRange<Int64>,total:Int64)throws{
        guard status==206,contentRange=="bytes \(range.lowerBound)-\(range.upperBound)/\(total)",bytes==range.upperBound-range.lowerBound+1 else{throw MapPackageError.invalidRange}
    }
}
