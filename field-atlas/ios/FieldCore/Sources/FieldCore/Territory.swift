import Foundation

public struct TerritoryChoice: Codable, Identifiable, Equatable {
    public let id: String
    public let title: String
}
public struct TerritoryPlace: Codable, Identifiable, Equatable {
    public let id: String
    public let siteId: String
    public let collection: String
    public let name: String
    public let category: String
    public let theme: String
    public let point: [Double]?
    public let approximate: Bool
    public let summary: String
    public let locality: String
    public let status: String
    public let periods: [String]
    public let periodBasis: String
    public let chronologyReviewed: Bool
    public let sources: [String]
    public let url: String
    public let noRoute: Bool
    public func matches(theme: String, period: String, query: String = "") -> Bool {
        let text=(name+" "+locality+" "+summary).lowercased().replacingOccurrences(of:"ё",with:"е")
        let search=query.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().replacingOccurrences(of:"ё",with:"е")
        return (theme=="all" || self.theme==theme) && (period=="all" || periods.contains(period)) && (search.isEmpty || text.contains(search))
    }
}
public struct TerritoryCatalog: Codable {
    public let schemaVersion: Int
    public let id: String
    public let revision: String
    public let title: String
    public let bounds: [[Double]]
    public let attribution: String
    public let coverage: String
    public let periodMeaning: String
    public let themes: [TerritoryChoice]
    public let periods: [TerritoryChoice]
    public let places: [TerritoryPlace]
    public func validated() throws -> Self {
        guard schemaVersion==1,id.range(of:"^[a-z0-9_-]{1,80}$",options:.regularExpression) != nil,!revision.isEmpty,revision.count<=64,
              bounds.count==2,bounds.allSatisfy(Self.validCoordinate),bounds[0][0]<bounds[1][0],bounds[0][1]<bounds[1][1],
              places.count<=10000,Set(places.map(\.id)).count==places.count,
              Set(themes.map(\.id)).count==themes.count,Set(periods.map(\.id)).count==periods.count else {throw TerritoryError.invalidPackage}
        for p in places {
            guard p.id==p.collection+":"+p.siteId,["heritage","directory"].contains(p.collection),!p.siteId.isEmpty,
                  p.point.map(Self.validCoordinate) ?? true, p.name.count<=500,p.summary.count<=20000,
                  themes.contains(where:{$0.id==p.theme}),p.periods.allSatisfy({id in periods.contains{$0.id==id}}),
                  p.periodBasis=="related_history",p.chronologyReviewed || p.periods.isEmpty,
                  let url=URL(string:p.url),url.scheme=="https",url.host=="archiverf.ru",url.user==nil,url.password==nil,
                  url.path=="/",url.fragment?.hasPrefix("places/atlas/vytegra/")==true else {throw TerritoryError.invalidPackage}
        }
        return self
    }
    public func contains(_ origin:GeoOrigin)->Bool {
        bounds.count==2 && bounds.allSatisfy(Self.validCoordinate) && origin.lat>=bounds[0][0] && origin.lat<=bounds[1][0] && origin.lon>=bounds[0][1] && origin.lon<=bounds[1][1]
    }
    public static func validCoordinate(_ point:[Double])->Bool {
        point.count==2 && point.allSatisfy(\.isFinite) && abs(point[0])<=85 && abs(point[1])<=180
    }
}
public enum TerritoryError: LocalizedError {
    case invalidPackage
    public var errorDescription: String? {"Пакет карты повреждён или имеет неподдерживаемый формат. Предыдущая карта сохранена."}
}
