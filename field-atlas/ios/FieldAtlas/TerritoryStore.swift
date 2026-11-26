import SwiftUI
import CryptoKit
import FieldCore

struct TerritoryManifest: Codable {
    struct Entry: Codable {let name:String;let bytes:Int;let sha256:String}
    let schemaVersion:Int;let id:String;let revision:String;let title:String;let files:[Entry]
    func validate() throws {
        guard schemaVersion==1,id.range(of:"^[a-z0-9_-]{1,80}$",options:.regularExpression) != nil,!revision.isEmpty,revision.count<=64,
              files.count==2,Set(files.map(\.name))==Set(["territory-catalog.json","territory-map.json"]),
              files.allSatisfy({(1...20_000_000).contains($0.bytes) && $0.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else {throw TerritoryError.invalidPackage}
    }
}

@MainActor final class TerritoryStore: ObservableObject {
    @Published private(set) var catalog:TerritoryCatalog?
    @Published private(set) var mapURL:URL?
    @Published private(set) var busy=false
    @Published private(set) var message="Открываем карту округа…"
    private var root:URL?
    private var operation:Task<Void,Never>?
    func load(root:URL) {
        guard self.root==nil else{return};self.root=root.appendingPathComponent("territories",isDirectory:true)
        do {
            if let directory=try cachedDirectory(){try install(directory);message="Карта сохранена для работы без связи";return}
        } catch {message="Сохранённое обновление повреждено. Открыта карта из приложения."}
        do {
            guard let url=Bundle.main.url(forResource:"territory-manifest",withExtension:"json") else{throw TerritoryError.invalidPackage}
            try install(url.deletingLastPathComponent())
            message="Карта округа доступна без интернета"
        } catch {message=error.localizedDescription}
    }
    private func cachedDirectory() throws -> URL? {
        guard let root else{return nil};let pointer=root.appendingPathComponent("current.txt")
        guard FileManager.default.fileExists(atPath:pointer.path)else{return nil}
        let name=try String(contentsOf:pointer,encoding:.utf8)
        guard name.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw TerritoryError.invalidPackage}
        return root.appendingPathComponent(name,isDirectory:true)
    }
    private func install(_ directory:URL) throws {
        let manifest=try JSONDecoder().decode(TerritoryManifest.self,from:Data(contentsOf:directory.appendingPathComponent("territory-manifest.json")))
        try manifest.validate()
        for entry in manifest.files {
            let data=try Data(contentsOf:directory.appendingPathComponent(entry.name),options:.mappedIfSafe)
            guard data.count==entry.bytes,Self.digest(data)==entry.sha256 else{throw TerritoryError.invalidPackage}
        }
        let value=try JSONDecoder().decode(TerritoryCatalog.self,from:Data(contentsOf:directory.appendingPathComponent("territory-catalog.json"))).validated()
        guard value.id==manifest.id,value.revision==manifest.revision else{throw TerritoryError.invalidPackage}
        let map=directory.appendingPathComponent("territory-map.json")
        let geo=try JSONSerialization.jsonObject(with:Data(contentsOf:map)) as? [String:Any]
        guard geo?["type"] as? String=="FeatureCollection",let features=geo?["features"] as? [[String:Any]],!features.isEmpty,features.count<=100000 else{throw TerritoryError.invalidPackage}
        catalog=value;mapURL=map
    }
    func update() {
        guard !busy,let root else{return};busy=true
        operation=Task {
            defer{busy=false;operation=nil}
            do {
                let base=URL(string:"https://archiverf.ru/static/atlas/vytegra/")!
                var request=URLRequest(url:base.appendingPathComponent("territory-manifest.json"));request.cachePolicy = .reloadIgnoringLocalCacheData;request.timeoutInterval=30
                let (data,response)=try await URLSession.shared.data(for:request)
                guard data.count<=64_000,(response as? HTTPURLResponse)?.statusCode==200,response.url?.host==base.host,response.url?.scheme=="https" else{throw TerritoryError.invalidPackage}
                let manifest=try JSONDecoder().decode(TerritoryManifest.self,from:data);try manifest.validate()
                let directory=root.appendingPathComponent(Self.digest(data),isDirectory:true)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                for (index,entry) in manifest.files.enumerated(){
                    try Task.checkCancellation();message="Обновление карты: файл \(index+1) из 2"
                    let target=directory.appendingPathComponent(entry.name)
                    if let existing=try? Data(contentsOf:target),existing.count==entry.bytes,Self.digest(existing)==entry.sha256{continue}
                    var fileRequest=URLRequest(url:base.appendingPathComponent(entry.name));fileRequest.timeoutInterval=90;fileRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    let (temporary,response)=try await URLSession.shared.download(for:fileRequest)
                    defer{try? FileManager.default.removeItem(at:temporary)}
                    try Task.checkCancellation()
                    let attributes=try FileManager.default.attributesOfItem(atPath:temporary.path)
                    guard (response as? HTTPURLResponse)?.statusCode==200,response.url?.host==base.host,response.url?.scheme=="https",(attributes[.size] as? NSNumber)?.intValue==entry.bytes else{throw TerritoryError.invalidPackage}
                    let bytes=try Data(contentsOf:temporary,options:.mappedIfSafe)
                    guard Self.digest(bytes)==entry.sha256 else{throw TerritoryError.invalidPackage}
                    try bytes.write(to:target,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                }
                try data.write(to:directory.appendingPathComponent("territory-manifest.json"),options:.atomic)
                try Task.checkCancellation()
                // Validate both files before switching the persistent pointer.
                let previousCatalog=catalog,previousURL=mapURL
                do {try install(directory);try Data(directory.lastPathComponent.utf8).write(to:root.appendingPathComponent("current.txt"),options:.atomic)}
                catch{catalog=previousCatalog;mapURL=previousURL;throw error}
                message="Версия \(manifest.revision) сохранена. Карта доступна без связи."
            } catch is CancellationError {message="Обновление остановлено. Предыдущая карта доступна."}
            catch{message="Не удалось обновить: "+error.localizedDescription+" Предыдущая карта сохранена."}
        }
    }
    func cancel(){operation?.cancel()}
    static func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
}
