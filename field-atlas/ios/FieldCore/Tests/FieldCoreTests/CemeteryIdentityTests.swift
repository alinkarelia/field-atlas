import XCTest
@testable import FieldCore

final class CemeteryIdentityTests:XCTestCase {
    private func evidence(_ text:String)->NameReadingEvidence{NameReadingEvidence(photoID:UUID().uuidString,sha256:String(repeating:"a",count:64),text:text,confidence:0.8,box:[0.1,0.2,0.6,0.1])}
    func testLegacyProjectsCardsAndPeopleDecodeWithoutNewFields()throws{
        let decoder=JSONDecoder(),encoder=JSONEncoder()
        let project=FieldProject(title:"Старая съёмка",type:.cemetery)
        var card=Observation(projectId:project.id,kind:"grave");var person=PersonReading();person.name="Иванов И. И.";card.persons=[person]
        let restored=try decoder.decode(Observation.self,from:encoder.encode(card))
        XCTAssertEqual(restored,card);XCTAssertNil(restored.entityID);XCTAssertNil(restored.persons.first?.evidence)
        let old:Data=Data("{\"id\":\"old\",\"name\":\"Иванов\",\"birth\":\"\",\"death\":\"\"}".utf8)
        XCTAssertEqual(try decoder.decode(PersonReading.self,from:old).name,"Иванов")
        XCTAssertEqual(try decoder.decode(FieldProject.self,from:encoder.encode(project)),project)
    }
    func testNameDatesAndOriginalAreRetainedWithoutInventingBirthDeath(){
        let source=evidence("12. ИВАНОВ ИВАН ИВАНОВИЧ 1910–1942")
        let person=MemorialNameParser.suggestion(source)
        XCTAssertEqual(person?.name,"ИВАНОВ ИВАН ИВАНОВИЧ");XCTAssertEqual(person?.datesText,"1910–1942")
        XCTAssertEqual(person?.birth,"");XCTAssertEqual(person?.death,"");XCTAssertEqual(person?.relation,"inscription")
        XCTAssertEqual(person?.needsReview,true);XCTAssertEqual(person?.evidence,[source])
        XCTAssertNotNil(MemorialNameParser.suggestion(evidence("Петров П. П.")))
        XCTAssertNotNil(MemorialNameParser.suggestion(evidence("СИДОРОВ А. В. 22.06.1941")))
    }
    func testHeadingsUnknownSoldiersAndMixedColumnsRemainUnparsed(){
        for line in ["ВЕЧНАЯ ПАМЯТЬ","ЗДЕСЬ ПОХОРОНЕНЫ","НЕИЗВЕСТНЫЙ СОЛДАТ","1941–1945","ИВАНОВ И. И. 1942 ПЕТРОВ П. П. 1943"]{XCTAssertNil(MemorialNameParser.suggestion(evidence(line)),line)}
        XCTAssertEqual(MemorialNameParser.normalize("Семёнов И. И."),MemorialNameParser.normalize("СЕМЕНОВ И И"))
    }
    func testMassBurialUnknownCountsAreNotZeroOrPeople(){
        var r=Observation(projectId:"project",kind:"grave");r.burialKind="mass"
        XCTAssertNil(r.totalMinimum);XCTAssertNil(r.totalMaximum);XCTAssertTrue(r.persons.isEmpty);XCTAssertNil(r.cemeteryValidationError)
        r.totalMinimum=200;r.totalMaximum=300;r.unidentifiedCount=250;XCTAssertNil(r.cemeteryValidationError)
        r.unidentifiedCount=301;XCTAssertNotNil(r.cemeteryValidationError);r.unidentifiedCount=nil;r.totalMinimum=301;XCTAssertNotNil(r.cemeteryValidationError)
        r.totalMinimum=nil;r.totalMaximum=nil;XCTAssertNil(r.cemeteryValidationError)
    }
    func testHierarchyRejectsCyclesAndForeignProjectButAllowsManyGraves(){
        var sector=Observation(projectId:"a",kind:"sector"),plot=Observation(projectId:"a",kind:"plot"),grave=Observation(projectId:"a",kind:"grave")
        plot.parentEntityID=sector.physicalID;grave.parentEntityID=plot.physicalID
        XCTAssertNil(CemeteryHierarchy.validationError([sector,plot,grave]))
        sector.parentEntityID=plot.physicalID;XCTAssertNotNil(CemeteryHierarchy.validationError([sector,plot,grave]))
        sector.parentEntityID=nil;plot.projectId="b";XCTAssertNotNil(CemeteryHierarchy.validationError([sector,plot,grave]))
        grave.parentEntityID=grave.physicalID;XCTAssertNotNil(grave.cemeteryValidationError)
    }
    func testNewObservationCanRetainPhysicalObjectWithoutReusingCardID()throws{
        let original=Observation(projectId:"a",kind:"grave");var later=Observation(projectId:"a",kind:"grave");later.entityID=original.physicalID
        XCTAssertNotEqual(original.id,later.id);XCTAssertEqual(original.physicalID,later.physicalID)
        XCTAssertEqual(try JSONDecoder().decode(Observation.self,from:JSONEncoder().encode(later)).physicalID,original.physicalID)
    }
}
