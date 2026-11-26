import XCTest
@testable import FieldAtlas
import FieldCore

final class TerritoryTests:XCTestCase {
    private func data(_ name:String)throws->Data{try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:name,withExtension:"json")))}
    @MainActor func testBundledMapMatchesWebsiteManifest()throws{
        let manifest=try JSONDecoder().decode(TerritoryManifest.self,from:data("territory-manifest"));try manifest.validate()
        for entry in manifest.files {let raw=try data(String(entry.name.dropLast(5)));XCTAssertEqual(raw.count,entry.bytes);XCTAssertEqual(TerritoryStore.digest(raw),entry.sha256)}
        let catalog=try JSONDecoder().decode(TerritoryCatalog.self,from:data("territory-catalog")).validated()
        XCTAssertEqual(catalog.revision,manifest.revision);XCTAssertEqual(catalog.id,manifest.id);XCTAssertEqual(catalog.places.count,162)
        XCTAssertTrue(catalog.contains(GeoOrigin(lat:61.004616,lon:36.443224)))
        XCTAssertFalse(catalog.contains(GeoOrigin(lat:59.9,lon:30.3)))
    }
    func testPeriodIsRelatedHistoryNotConstructionOrExistence()throws{
        let catalog=try JSONDecoder().decode(TerritoryCatalog.self,from:data("territory-catalog")).validated()
        let museum=try XCTUnwrap(catalog.places.first{$0.siteId=="first-vytegra-hpp"})
        XCTAssertTrue(museum.matches(theme:"work",period:"soviet"));XCTAssertTrue(museum.matches(theme:"work",period:"since1992"))
        XCTAssertEqual(museum.periodBasis,"related_history")
        let unknown=try XCTUnwrap(catalog.places.first{!$0.chronologyReviewed})
        XCTAssertTrue(unknown.matches(theme:"all",period:"all"));XCTAssertFalse(unknown.matches(theme:"all",period:"soviet"))
    }
    func testRejectsUnsafeCardLinksAndInvalidBounds()throws{
        let raw=try data("territory-catalog")
        for mode in ["link","bounds","duplicate","schema"] {
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
            var places=try XCTUnwrap(object["places"] as? [[String:Any]])
            if mode=="link"{places[0]["url"]="https://archiverf.ru.attacker.invalid/#places/atlas/vytegra/x";object["places"]=places}
            if mode=="bounds"{object["bounds"]=[[91,36],[92,37]]}
            if mode=="duplicate"{places.append(places[0]);object["places"]=places}
            if mode=="schema"{object["schemaVersion"]=2}
            let mutated=try JSONSerialization.data(withJSONObject:object)
            XCTAssertThrowsError(try JSONDecoder().decode(TerritoryCatalog.self,from:mutated).validated(),mode)
        }
    }
    @MainActor func testOfflineLoadAndDamagedUpdateFallback()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let cached=root.appendingPathComponent("territories");try FileManager.default.createDirectory(at:cached,withIntermediateDirectories:true)
        try Data("../../outside".utf8).write(to:cached.appendingPathComponent("current.txt"))
        let store=TerritoryStore();store.load(root:root)
        XCTAssertNotNil(store.catalog);XCTAssertTrue(store.mapURL?.isFileURL==true);XCTAssertFalse(store.busy)
    }
}
