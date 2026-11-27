import Foundation
import SwiftUI
import CryptoKit
import FieldCore
import ImageIO
import UniformTypeIdentifiers

struct AssetEntry: Codable, Identifiable {
    var id: String; var projectId: String; var filename: String; var mime: String; var sha256: String; var size: Int; var uploaded=false
}
struct Mutation: Codable, Identifiable {
    var id=UUID().uuidString; var record: Observation; var attemptBase: Int?; var state="pending"; var error: String?
}
struct WorldMapReference: Codable { var frameId: String; var filename: String }
struct AtlasState: Codable {
    var schemaVersion=1
    var projects: [FieldProject]=[]; var records: [Observation]=[]; var assets: [AssetEntry]=[]; var outbox: [Mutation]=[]; var scans: [ScanReference]=[]
    var origins: [String:GeoOrigin]=[:]; var worldMaps: [String:WorldMapReference]=[:]
}
@MainActor final class AppStore: ObservableObject {
    @Published private(set) var state=AtlasState()
    @Published var error: String?
    @Published private(set) var identityCodes:[String:FieldIdentityCodes]=[:]
    private var readOnly=false
    let root: URL
    let encoder: JSONEncoder = { let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return e }()
    init() {
        var directory="FieldAtlas"
        #if DEBUG
        if let session=ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"],let uuid=UUID(uuidString:session){directory="FieldAtlas-UITests-"+uuid.uuidString}
        #endif
        root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(directory,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:root.appendingPathComponent("assets",isDirectory:true),withIntermediateDirectories:true)
            let file=root.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath:file.path) {
                let loaded=try JSONDecoder().decode(AtlasState.self,from:Data(contentsOf:file))
                guard loaded.schemaVersion==1 else { throw CocoaError(.coderReadCorrupt) };state=loaded
            }
        } catch { readOnly=true;self.error="Не удалось открыть локальные данные. Исходные файлы сохранены: \(error.localizedDescription)" }
        identityCodes=(try? JSONDecoder().decode([String:FieldIdentityCodes].self,from:Data(contentsOf:root.appendingPathComponent("identity-codes.json")))) ?? [:]
    }
    func saveIdentityCodes(_ codes:FieldIdentityCodes,projectID:String)throws{
        var next=identityCodes;next[projectID]=codes
        try encoder.encode(next).write(to:root.appendingPathComponent("identity-codes.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]);identityCodes=next
    }
    private func persist(_ next: AtlasState) throws {
        guard !readOnly else { throw CocoaError(.fileWriteUnknown) }
        let data=try encoder.encode(next)
        try data.write(to:root.appendingPathComponent("state.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]);state=next
    }
    func trackURL(_ projectId:String)->URL{root.appendingPathComponent("track-"+projectId+".json")}
    func saveTrack(_ value:TrackSnapshot,projectId:String)throws{guard !readOnly else{throw CocoaError(.fileWriteUnknown)};try encoder.encode(value).write(to:trackURL(projectId),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
    func loadTrack(_ projectId:String)->TrackSnapshot?{try? JSONDecoder().decode(TrackSnapshot.self,from:Data(contentsOf:trackURL(projectId)))}
    func clearTrack(_ projectId:String)throws{let file=trackURL(projectId);if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)}}
    func addProject(_ project: FieldProject) throws { var next=state;next.projects.append(project);try persist(next) }
    func records(_ projectId: String) -> [Observation] { state.records.filter{$0.projectId==projectId} }
    func save(_ record: Observation) throws {
        try saveAll([record])
    }
    func saveAll(_ records:[Observation]) throws {
        var next=state;var changed=false
        for record in records{
            guard let project=state.projects.first(where:{$0.id==record.projectId}),!["grave","plot","sector"].contains(record.kind) || project.type == .cemetery,record.roomPlan == nil || project.type == .interior && record.kind=="room",try encoder.encode(record).count<=2*1024*1024 else { throw CocoaError(.validationMissingMandatoryProperty) }
            if let problem=record.cemeteryValidationError{throw SiteTransferError.message(problem)}
            var copy=record;let old=next.records.first(where:{$0.id==record.id})
            if let old,old.projectId != record.projectId {throw CocoaError(.validationMissingMandatoryProperty)}
            if let old{var comparable=record;comparable.serverVersion=old.serverVersion;comparable.localRevision=old.localRevision;comparable.dirty=old.dirty;if comparable==old{continue}}
            copy.serverVersion=old?.serverVersion ?? 0;copy.localRevision=(old?.localRevision ?? 0)+1;copy.dirty=true
            next.records.removeAll{$0.id==copy.id};next.records.append(copy);// Pending, never-attempted edits may be coalesced. In-flight mutations are immutable.
            next.outbox.removeAll{$0.record.id==copy.id && $0.attemptBase==nil && $0.state=="pending"}
            next.outbox.append(Mutation(record:copy));changed=true
        }
        if changed{if let problem=CemeteryHierarchy.validationError(next.records){throw SiteTransferError.message(problem)};try persist(next)}
    }
    func attachCeiling(_ value:CeilingMeasurement,roomId:String,projectId:String)throws->MeasuredRoom{
        guard value.valid,let original=records(projectId).compactMap({$0.roomPlan?.rooms.first(where:{$0.id==roomId})}).first else{throw CocoaError(.validationMissingMandatoryProperty)}
        let asset=try saveAsset(encoder.encode(value),projectId:projectId,mime:"application/json",extension:"json")
        var room=original;room.ceiling=value
        room.ceilingSourceHistory=Array(Set((room.ceilingSourceHistory ?? [])+[room.ceilingSourceId].compactMap{$0})).sorted()
        room.ceilingSourceId=asset.id;room.ceilingSource=value.method=="plane-proposal" ? "ARKit: предложенный контур, проверен человеком":"AR: точки выбраны вручную"
        let heights=value.heights;room.ceilingHeight=(heights.max()! - heights.min()! <= 0.05) ? value.meanHeight:nil
        let changed=records(projectId).filter{$0.roomPlan?.rooms.contains(where:{$0.id==roomId}) == true}.map{record -> Observation in
            var copy=record;if let index=copy.roomPlan?.rooms.firstIndex(where:{$0.id==roomId}){copy.roomPlan?.rooms[index]=room};return copy
        }
        try saveAll(changed);return room
    }
    func setOrigin(_ origin: GeoOrigin,projectId: String) throws {var next=state;next.origins[projectId]=origin;try persist(next)}
    func assetURL(_ id: String) -> URL? { guard let a=state.assets.first(where:{$0.id==id}) else{return nil};return root.appendingPathComponent("assets").appendingPathComponent(a.filename) }
    func attachPhoto(_ data:Data,to record:Observation,role:String)throws->Observation {
        guard ["overview","inscription","portrait","detail"].contains(role),data.count<=100_000_000,
              let source=CGImageSourceCreateWithData(data as CFData,nil),let raw=CGImageSourceGetType(source) else{throw CocoaError(.fileReadCorruptFile)}
        let types:[String:(String,String)]=[UTType.jpeg.identifier:("jpg","image/jpeg"),UTType.png.identifier:("png","image/png"),UTType.heic.identifier:("heic","image/heic"),UTType.heif.identifier:("heif","image/heic")]
        guard let format=types[raw as String] else{throw SiteTransferError.message("Поддерживаются фотографии JPEG, PNG и HEIC. Исходный файл не изменён.")}
        let asset=try saveAsset(data,projectId:record.projectId,mime:format.1,extension:format.0)
        var next=record;next.photos.append(PhotoAttachment(id:asset.id,role:role,sha256:asset.sha256,name:asset.filename))
        try save(next);return next
    }
    @discardableResult func saveAsset(_ data: Data,projectId: String,mime: String,extension ext: String) throws -> AssetEntry {
        guard state.projects.contains(where:{$0.id==projectId}),["jpg","png","heic","heif","json","bin","worldmap","usdz","gpx"].contains(ext) else {throw CocoaError(.validationMissingMandatoryProperty)}
        let id=UUID().uuidString,filename="\(id).\(ext)";let sha=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let a=AssetEntry(id:id,projectId:projectId,filename:filename,mime:mime,sha256:sha,size:data.count)
        try data.write(to:root.appendingPathComponent("assets").appendingPathComponent(filename),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        var next=state;next.assets.append(a);try persist(next);return a
    }
    func saveScan(_ chunk: ScanChunk,projectId: String) throws {
        let asset=try saveAsset(encoder.encode(chunk),projectId:projectId,mime:"application/json",extension:"json")
        var next=state;next.scans.append(ScanReference(chunk:chunk,projectId:projectId,assetId:asset.id));try persist(next)
    }
    func saveWorldMap(_ data: Data,frameId: String,projectId: String) throws {
        let a=try saveAsset(data,projectId:projectId,mime:"application/octet-stream",extension:"worldmap")
        var next=state;next.worldMaps[projectId]=WorldMapReference(frameId:frameId,filename:a.filename);try persist(next)
    }
    func updateMutation(_ id: String,base: Int?=nil,error: String?=nil) throws {
        var next=state;guard let i=next.outbox.firstIndex(where:{$0.id==id}) else{return}
        if let base{next.outbox[i].attemptBase=base};if let error{next.outbox[i].state="conflict";next.outbox[i].error=error};try persist(next)
    }
    func acknowledge(_ mutation: Mutation,version: Int) throws {
        var next=state;next.outbox.removeAll{$0.id==mutation.id}
        if let i=next.records.firstIndex(where:{$0.id==mutation.record.id}){next.records[i].serverVersion=version;next.records[i].dirty=next.records[i].localRevision != mutation.record.localRevision}
        try persist(next)
    }
    func uploaded(_ id: String) throws {var next=state;if let i=next.assets.firstIndex(where:{$0.id==id}){next.assets[i].uploaded=true};try persist(next)}
    func loadPreview(projectId:String,frameId:String)->SurfacePreview {
        var preview=SurfacePreview()
        for ref in state.scans where ref.projectId==projectId && ref.frameId==frameId {
            guard let url=assetURL(ref.assetId),let data=try? Data(contentsOf:url),let chunk=try? JSONDecoder().decode(ScanChunk.self,from:data) else{continue}
            preview.add(chunk.points)
        }
        return preview
    }
    func loadPoints(projectId: String,frameId: String?=nil) -> [[Double]] {
        let references=state.scans.filter{$0.projectId==projectId && (frameId == nil || $0.frameId==frameId)}
        // Only load a bounded preview; original files remain intact.
        var points: [[Double]]=[]
        for ref in references.suffix(8) {
            guard let url=assetURL(ref.assetId),let data=try? Data(contentsOf:url),let chunk=try? JSONDecoder().decode(ScanChunk.self,from:data) else{continue}
            points.append(contentsOf:chunk.points);if points.count>100000{points=Array(points.suffix(100000))}
        }
        return points
    }
}
