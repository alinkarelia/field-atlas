import Foundation

public enum BurialKind:String,CaseIterable,Identifiable,Codable {
    case unknown,individual,family,collective,mass,memorial
    public var id:String{rawValue}
    public var title:String{switch self{case .unknown:return "Не определено";case .individual:return "Индивидуальное";case .family:return "Семейное";case .collective:return "Братская могила";case .mass:return "Массовое захоронение";case .memorial:return "Памятник / кенотаф"}}
}
public enum BurialRelation:String,CaseIterable,Identifiable,Codable {
    case inscription,interred,commemorated,unconfirmed
    public var id:String{rawValue}
    public var title:String{switch self{case .inscription:return "Имя на памятнике";case .interred:return "Погребён здесь · есть источник";case .commemorated:return "Увековечен, место погребения иное / неизвестно";case .unconfirmed:return "Связь требует проверки"}}
}
public struct NameReadingEvidence:Codable,Equatable {
    public var photoID:String;public var sha256:String;public var text:String;public var confidence:Double;public var box:[Double]
    public init(photoID:String,sha256:String,text:String,confidence:Double,box:[Double]){self.photoID=photoID;self.sha256=sha256;self.text=text;self.confidence=confidence;self.box=box}
}
public extension Observation {
    var physicalID:String{entityID ?? id}
    func followupObservation()->Observation{
        var next=Observation(projectId:projectId,kind:kind);next.entityID=physicalID;next.parentEntityID=parentEntityID;next.localNumber=localNumber;next.title=title
        next.burialKind=burialKind;next.totalMinimum=totalMinimum;next.totalMaximum=totalMaximum;next.unidentifiedCount=unidentifiedCount;next.countSource=countSource
        next.point=point;next.origin=origin;next.locationMethod="previous_observation";next.locationAccuracy=locationAccuracy;next.needsReview=true
        next.comments="Продолжение карточки "+id+". Место и сведения перенесены из предыдущего обследования и требуют проверки."
        return next
    }
    var cemeteryValidationError:String?{
        if persons.count>2000{return "В одной карточке допускается до 2 000 записей имён. Сохраните следующую часть отдельной карточкой того же объекта."}
        if let parentEntityID,parentEntityID==physicalID{return "Объект не может быть собственным участком."}
        for value in [totalMinimum,totalMaximum,unidentifiedCount].compactMap({$0}){if !(0...1_000_000).contains(value){return "Число погребённых должно быть от 0 до 1 000 000."}}
        if let a=totalMinimum,let b=totalMaximum,a>b{return "Нижняя оценка числа погребённых больше верхней."}
        if let a=unidentifiedCount,let b=totalMaximum,a>b{return "Неизвестных не может быть больше указанной верхней оценки."}
        return nil
    }
}
public enum CemeteryHierarchy {
    public static func validationError(_ records:[Observation])->String?{
        for r in records {
            var seen:Set<String>=[r.physicalID];var parent=r.parentEntityID
            while let id=parent{
                guard let p=records.first(where:{$0.projectId==r.projectId && $0.physicalID==id && ["plot","sector"].contains($0.kind)})else{return "Родительский участок не найден в этом проекте."}
                if !seen.insert(id).inserted{return "Участки не могут ссылаться друг на друга по кругу."};parent=p.parentEntityID
            }
        };return nil
    }
}

public struct FieldIdentity:Codable,Equatable{public let objectID:String;public let code:String}
public struct FieldIdentityCodes:Codable,Equatable{public let project:FieldIdentity;public let site:FieldIdentity?;public let entities:[String:FieldIdentity];public let records:[String:FieldIdentity];public let readings:[String:FieldIdentity]}
/// Suggestions only: one physical burial can contain zero, one or many name readings.
/// A reading is not a canonical person and is never an automatic graph merge.
public enum MemorialNameParser {
    public static func normalize(_ text:String)->String{text.uppercased().replacingOccurrences(of:"Ё",with:"Е").replacingOccurrences(of:"[^\\p{L}\\p{N}]",with:"",options:.regularExpression)}
    public static func suggestion(_ source:NameReadingEvidence)->PersonReading?{
        let raw=source.text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard raw.count>=4,raw.count<=220 else{return nil}
        let upper=raw.uppercased()
        let headings=["ВЕЧНАЯ ПАМЯТЬ","ВЕЧНАЯ СЛАВА","БРАТСКАЯ МОГИЛА","НЕИЗВЕСТНЫЙ","НЕИЗВЕСТНЫХ","ЗДЕСЬ ПОХОРОН","ПАВШИМ","ПОГИБШИМ","ЗА РОДИНУ","НИКТО НЕ ЗАБЫТ","ИМЯ НЕИЗВЕСТНО"]
        guard !headings.contains(where:{upper.contains($0)}) else{return nil}
        let cleaned=raw.replacingOccurrences(of:"^\\s*\\d+[.)]\\s*",with:"",options:.regularExpression)
        let pattern="(?:[0-3]?\\d[./][01]?\\d[./])?(?:1[6-9]\\d{2}|20\\d{2})(?:[?])?"
        let regex=try! NSRegularExpression(pattern:pattern)
        let matches=regex.matches(in:cleaned,range:NSRange(cleaned.startIndex...,in:cleaned))
        guard matches.count<=2 else{return nil}
        let first=matches.first.flatMap{Range($0.range,in:cleaned)}
        let name=(first.map{String(cleaned[..<$0.lowerBound])} ?? cleaned).trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"—–-,:;")))
        guard name.range(of:"^[\\p{L}][\\p{L} .’'?-]{3,100}$",options:.regularExpression) != nil else{return nil}
        let letters=name.split(whereSeparator:{$0==" " || $0=="."}).filter{!$0.isEmpty}
        guard (2...4).contains(letters.count) else{return nil}
        // Text from two columns in the same OCR row must not become one invented person.
        if let first{let suffix=cleaned[first.lowerBound...].replacingOccurrences(of:pattern,with:"",options:.regularExpression);if suffix.range(of:"[\\p{L}]",options:.regularExpression) != nil{return nil}}
        var person=PersonReading();person.name=name;person.relation=BurialRelation.inscription.rawValue;person.evidence=[source];person.needsReview=true
        person.datesText=first.map{String(cleaned[$0.lowerBound...])}
        // Dates retain their original text. Birth/death meaning is confirmed by the reviewer.
        return person
    }
}
