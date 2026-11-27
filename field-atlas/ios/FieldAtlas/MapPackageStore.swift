import SwiftUI
import CryptoKit
import Network
import FieldCore

@MainActor final class MapPackageStore:ObservableObject {
    @Published private(set) var catalog:MapPackageCatalog?
    @Published private(set) var installed:[String:MapPackage]=[:]
    @Published private(set) var activeID:String?
    @Published private(set) var progress:Double=0
    @Published private(set) var downloadedBytes:Int64=0
    @Published private(set) var message=""
    @Published private(set) var styleURL:URL?
    @Published private(set) var activeMapName="Карта мира"
    @Published private(set) var offlineReady=false
    @Published private(set) var networkAvailable=true
    @Published private(set) var checking=Set<String>()
    @Published var selectedID:String?
    private var root:URL?
    private var operation:Task<Void,Never>?
    private var monitor:NWPathMonitor?
    private var context:GeoOrigin?
    private var sourceKey=""
    private var onlineFailed=false
    private let session:URLSession
    private let monitorNetwork:Bool
    private var bundled:[String:MapPackage]=[:]
    private var cachedCatalog:URL?{root?.appendingPathComponent("catalog.json")}
    var packages:[MapPackage]{catalog?.packages ?? []}
    var busy:Bool{activeID != nil}
    init(session:URLSession = .shared,monitorNetwork:Bool=true,online:Bool=true){self.session=session;self.monitorNetwork=monitorNetwork;self.networkAvailable=online}
    func load(root:URL){
        guard self.root==nil else{return};let directory=root.appendingPathComponent("map-library",isDirectory:true);self.root=directory
        do{
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var values=URLResourceValues();values.isExcludedFromBackup=true;var excluded=directory;try excluded.setResourceValues(values)
            if let url=Bundle.main.url(forResource:"map-packages",withExtension:"json"){catalog=try JSONDecoder().decode(MapPackageCatalog.self,from:Data(contentsOf:url)).validated();bundled=Dictionary(uniqueKeysWithValues:(catalog?.packages ?? []).filter{$0.bundledResource != nil}.map{($0.id,$0)})}
            if let cache=cachedCatalog,let bytes=try? Data(contentsOf:cache),let saved=try? JSONDecoder().decode(MapPackageCatalog.self,from:bytes).validated(){catalog=saved}
            let records=directory.appendingPathComponent("installed.json")
            if let bytes=try? Data(contentsOf:records),let saved=try? JSONDecoder().decode([String:MapPackage].self,from:bytes){
                for (id,item) in saved where id==item.id && (try? item.validated()) != nil {
                    checking.insert(id)
                    Task{do{let url=directory.appendingPathComponent(item.sha256+".pmtiles");try await Task.detached(priority:.utility){try Self.verify(url,item)}.value;installed[id]=item}catch{message="Карта «\(item.title)» повреждена. Её можно загрузить снова."};checking.remove(id);updateContext(context)}
                }
            }
            if let data=try? Data(contentsOf:directory.appendingPathComponent("selection.txt")),let id=String(data:data,encoding:.utf8),packages.contains(where:{$0.id==id}){selectedID=id}
        }catch{message=error.localizedDescription}
        var observeNetwork=monitorNetwork
        #if DEBUG
        if ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"] != nil,ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_OFFLINE"]=="1"{networkAvailable=false;observeNetwork=false}
        #endif
        if observeNetwork{let monitor=NWPathMonitor();self.monitor=monitor;monitor.pathUpdateHandler={[weak self] path in let online=path.status == .satisfied;Task{@MainActor in guard let self else{return};let changed=self.networkAvailable != online;self.networkAvailable=online;if changed{self.onlineFailed=false;self.updateContext(self.context)}}};monitor.start(queue:DispatchQueue(label:"atlas.map-connectivity"))}
        updateContext(nil)
    }
    func localURL(_ package:MapPackage)->URL?{
        if let saved=installed[package.id],let root{let url=root.appendingPathComponent(saved.sha256+".pmtiles");if FileManager.default.fileExists(atPath:url.path){return url}}
        if let name=bundled[package.id]?.bundledResource{return Bundle.main.url(forResource:name,withExtension:"pmtiles")}
        return nil
    }
    func isCurrent(_ package:MapPackage)->Bool{installed[package.id]?.sha256==package.sha256 || (bundled[package.id]?.sha256==package.sha256 && localURL(package) != nil)}
    func partialBytes(_ package:MapPackage)->Int64{guard let root else{return 0};return ((try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(package.sha256+".part").path)[.size]) as? NSNumber)?.int64Value ?? 0}
    func select(_ package:MapPackage){selectedID=package.id;if let root{try? Data(package.id.utf8).write(to:root.appendingPathComponent("selection.txt"),options:.atomic)};updateContext(package.center)}
    func updateContext(_ point:GeoOrigin?){
        context=point
        if networkAvailable && !onlineFailed{configureOnline();return}
        let candidates=packages.filter{package in point.map{package.contains($0)} ?? (package.id==selectedID)}.sorted{$0.area==$1.area ? $0.maxZoom>$1.maxZoom:$0.area<$1.area}
        let local=candidates.first{localURL($0) != nil}
        let remote=candidates.first
        let package=local ?? remote
        if let package,let url=localURL(package){configure(package:package,url:url,offline:true);return}
        if let url=Bundle.main.url(forResource:"world-overview",withExtension:"pmtiles"){configure(package:nil,url:url,offline:true)}
    }
    private func configureOnline(){
        guard let revision=catalog?.revision,let root else{return}
        activeMapName="Наша карта · онлайн";offlineReady=false
        let key="online-"+revision;guard sourceKey != key else{return}
        do{
            guard let template=Bundle.main.url(forResource:"field-basemap",withExtension:"json")else{throw MapPackageError.invalidCatalog}
            var style=try JSONSerialization.jsonObject(with:Data(contentsOf:template)) as! [String:Any]
            style["sources"]=["protomaps":["type":"vector","tiles":["https://archiverf.ru/api/maps/tiles/"+revision+"/{z}/{x}/{y}.mvt"],"minzoom":0,"maxzoom":14,"attribution":"© OpenStreetMap · Protomaps"]]
            style["glyphs"]=Bundle.main.resourceURL!.appendingPathComponent("MapAssets/fonts").absoluteString+"/{fontstack}/{range}.pbf"
            style["sprite"]=Bundle.main.resourceURL!.appendingPathComponent("MapAssets/sprites/light").absoluteString
            let target=root.appendingPathComponent("style-"+key+".json");try JSONSerialization.data(withJSONObject:style).write(to:target,options:.atomic);sourceKey=key;styleURL=target
        }catch{message=error.localizedDescription}
    }
    func mapFailed(){guard !onlineFailed else{return};onlineFailed=true;message="Онлайн-карта недоступна. Открыта сохранённая подложка.";updateContext(context)}
    func retryOnline(){onlineFailed=false;updateContext(context)}
    private func configure(package:MapPackage?,url:URL,offline:Bool){
        activeMapName=package?.title ?? "Мир · обзор";offlineReady=offline
        let key=url.absoluteString;guard sourceKey != key,let root else{return}
        do{
            guard let template=Bundle.main.url(forResource:"field-basemap",withExtension:"json") else{throw MapPackageError.invalidCatalog}
            var style=try JSONSerialization.jsonObject(with:Data(contentsOf:template)) as! [String:Any]
            var source:[String:Any]=["type":"vector","url":"pmtiles://"+url.absoluteString,"attribution":"© OpenStreetMap · Protomaps"]
            if let package{source["bounds"]=package.bounds}
            style["sources"]=["protomaps":source]
            guard let fonts=Bundle.main.resourceURL?.appendingPathComponent("MapAssets/fonts",isDirectory:true),let sprites=Bundle.main.resourceURL?.appendingPathComponent("MapAssets/sprites/light") else{throw MapPackageError.invalidCatalog}
            style["glyphs"]=fonts.absoluteString+"/{fontstack}/{range}.pbf";style["sprite"]=sprites.absoluteString
            let target=root.appendingPathComponent("style-"+TerritoryStore.digest(Data(key.utf8))+".json")
            // App updates can change the bundle directory. Rewrite local resource
            // URLs so a downloaded map never retains a removed bundle's fonts.
            try JSONSerialization.data(withJSONObject:style).write(to:target,options:.atomic)
            sourceKey=key;styleURL=target
        }catch{message=error.localizedDescription}
    }
    func refreshCatalog()async{
        do{let url=URL(string:"https://archiverf.ru/static/maps/catalog.json")!;var request=URLRequest(url:url);request.cachePolicy = .reloadIgnoringLocalCacheData;request.timeoutInterval=25
            let (data,response)=try await session.data(for:request);guard (response as? HTTPURLResponse)?.statusCode==200,data.count<=2_000_000,response.url==url else{throw MapPackageError.invalidCatalog}
            let value=try JSONDecoder().decode(MapPackageCatalog.self,from:data).validated();if let cache=cachedCatalog{try data.write(to:cache,options:.atomic)};catalog=value;message="Каталог карт обновлён";updateContext(context)
        }catch{message="Каталог не обновлён. Сохранённые карты и загрузки доступны."}
    }
    func pause(){operation?.cancel()}
    func start(_ package:MapPackage){
        guard !busy,let root else{return};activeID=package.id;progress=0
        operation=Task{defer{activeID=nil;operation=nil};do{
            _ = try package.validated();let part=root.appendingPathComponent(package.sha256+".part")
            var offset=partialBytes(package);if offset>package.bytes{throw MapPackageError.damagedFile}
            let resources=try root.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey,.volumeAvailableCapacityKey]);let capacity=resources.volumeAvailableCapacityForImportantUsage ?? Int64(resources.volumeAvailableCapacity ?? 0)
            guard capacity>=package.bytes-offset+32*1024*1024 else{throw MapPackageError.noSpace}
            if !FileManager.default.fileExists(atPath:part.path){try Data().write(to:part,options:.atomic)}
            let file=try FileHandle(forWritingTo:part);defer{try? file.close()};try file.seek(toOffset:UInt64(offset))
            while offset<package.bytes {
                try Task.checkCancellation();let range=try MapDownloadPolicy.range(offset:offset,total:package.bytes)
                var request=URLRequest(url:URL(string:package.url)!);request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)",forHTTPHeaderField:"Range");request.setValue("identity",forHTTPHeaderField:"Accept-Encoding");request.setValue("Archiverf-FieldAtlas/0.7",forHTTPHeaderField:"User-Agent");request.cachePolicy = .reloadIgnoringLocalCacheData;request.timeoutInterval=90
                message="Загружаем «\(package.title)» с Google Диска через сайт";let (temporary,response)=try await session.download(for:request);defer{try? FileManager.default.removeItem(at:temporary)}
                try Task.checkCancellation();guard let http=response as? HTTPURLResponse,response.url?.absoluteString==package.url else{throw MapPackageError.invalidRange}
                let size=(try FileManager.default.attributesOfItem(atPath:temporary.path)[.size] as? NSNumber)?.int64Value ?? -1
                try MapDownloadPolicy.validateResponse(status:http.statusCode,contentRange:http.value(forHTTPHeaderField:"Content-Range"),bytes:size,range:range,total:package.bytes)
                let bytes=try Data(contentsOf:temporary);try file.write(contentsOf:bytes);try file.synchronize();offset+=Int64(bytes.count);downloadedBytes=offset;progress=Double(offset)/Double(package.bytes)
            }
            try file.close();try Task.checkCancellation();message="Проверяем карту…";checking.insert(package.id);defer{checking.remove(package.id)}
            do{try await Task.detached(priority:.utility){try Self.verify(part,package)}.value}catch{try? Data().write(to:part,options:.atomic);throw error}
            try Task.checkCancellation();let target=root.appendingPathComponent(package.sha256+".pmtiles")
            if FileManager.default.fileExists(atPath:target.path){_ = try FileManager.default.replaceItemAt(target,withItemAt:part)}else{try FileManager.default.moveItem(at:part,to:target)}
            var next=installed;next[package.id]=package;try JSONEncoder().encode(next).write(to:root.appendingPathComponent("installed.json"),options:.atomic);installed=next;message="«\(package.title)» готова без интернета";updateContext(context)
        }catch is CancellationError{message="Загрузка приостановлена. Уже принятая часть сохранена."}catch{message=error.localizedDescription}}
    }
    func remove(_ package:MapPackage){
        guard !busy,let root,let saved=installed[package.id] else{return}
        do{var next=installed;next.removeValue(forKey:package.id);try JSONEncoder().encode(next).write(to:root.appendingPathComponent("installed.json"),options:.atomic);installed=next
            let url=root.appendingPathComponent(saved.sha256+".pmtiles");if !next.values.contains(where:{$0.sha256==saved.sha256}){try? FileManager.default.removeItem(at:url)};sourceKey="";updateContext(context);message="Подложка удалена. Проекты и съёмки сохранены."
        }catch{message=error.localizedDescription}
    }
    nonisolated static func verify(_ url:URL,_ package:MapPackage)throws{
        let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.int64Value
        guard size==package.bytes else{throw MapPackageError.damagedFile}
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};let header=try file.read(upToCount:8) ?? Data()
        guard header==Data([80,77,84,105,108,101,115,3])else{throw MapPackageError.damagedFile};try file.seek(toOffset:0)
        var hash=SHA256();while let bytes=try file.read(upToCount:4*1024*1024),!bytes.isEmpty{hash.update(data:bytes)}
        guard hash.finalize().map({String(format:"%02x",$0)}).joined()==package.sha256 else{throw MapPackageError.damagedFile}
    }
}
