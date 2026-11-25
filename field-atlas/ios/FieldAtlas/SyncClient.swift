import Foundation
import SwiftUI
import FieldCore

struct UploadState: Decodable {
    var id:String;var size:Int;var offset:Int;var complete:Int
    func validate(_ asset:AssetEntry, expectedOffset:Int?=nil)throws {
        guard id==asset.id,size==asset.size,size>=0,(0...size).contains(offset),[0,1].contains(complete),
              complete==0 || offset==size,expectedOffset==nil || offset==expectedOffset else {throw StaffAccountError.invalidResponse}
    }
}
struct RecordAcknowledgement: Decodable {var id:String;var version:Int}
struct ServerError: Decodable {var error:String}
struct AssemblyResult: Decodable {struct Pending:Decodable{var id:String;var reason:String};var id:String;var projectId:String;var registered:[String];var pending:[Pending];var coverage:[CoverageCell]}
struct AssemblyJob:Codable {var id:String;var projectId:String;var state:String;var progress:Double?;var message:String?;var error:String?;var assemblyId:String?}
struct AssemblyList:Decodable {var assemblies:[AssemblyResult]}
struct ReadingResult: Codable {var text:String;var sourceHash:String;var originalSourceHash:String?;var verified:Bool}
struct OCRJob: Codable {var id:String;var recordId:String;var assetId:String;var sourceHash:String;var state:String;var error:String?;var result:ReadingResult?}
enum NetworkProblem: LocalizedError {
    case configuration, response(Int,String)
    var errorDescription:String?{switch self{case .configuration:return "Укажите адрес сервера в настройках передачи";case .response(_,let text):return text}}
}
@MainActor final class SyncClient:ObservableObject {
    @Published var busy=false
    @Published var message="Материалы сохраняются на устройстве"
    @Published var progress:Double=0
    @Published var assembly:AssemblyResult?
    @Published var reading:OCRJob?
    @Published var assemblyJob:AssemblyJob?
    var baseURL:String {UserDefaults.standard.string(forKey:"serverURL") ?? ""}
    private func url(_ path:String)throws->URL {
        guard let base=URL(string:baseURL),let scheme=base.scheme,let host=base.host,
              scheme=="https" || (scheme=="http" && ["localhost","127.0.0.1"].contains(host)),
              let value=URL(string:path,relativeTo:base)?.absoluteURL else{throw NetworkProblem.configuration}
        return value
    }
    func request<T:Decodable>(_ path:String,method:String="GET",data:Data?=nil,headers:[String:String]=[:])async throws->T {
        var request=URLRequest(url:try url(path));request.httpMethod=method;request.httpBody=data;request.timeoutInterval=45
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        for (k,v) in headers{request.setValue(v,forHTTPHeaderField:k)}
        let (body,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse else{throw NetworkProblem.response(0,"Ответ сервера не распознан")}
        guard (200..<300).contains(response.statusCode) else{let text=(try? JSONDecoder().decode(ServerError.self,from:body).error) ?? "Ошибка сервера \(response.statusCode)";throw NetworkProblem.response(response.statusCode,text)}
        return try JSONDecoder().decode(T.self,from:body)
    }
    func synchronize(_ store:AppStore)async {
        guard !busy else{return};busy=true;defer{busy=false}
        do{
            for project in store.state.projects{let _:FieldProject=try await request("/api/projects",method:"POST",data:store.encoder.encode(project))}
            var blocked=Set<String>()
            for m in store.state.outbox {
                if m.state=="conflict" || blocked.contains(m.record.id){blocked.insert(m.record.id);continue}
                let base=m.attemptBase ?? store.state.records.first(where:{$0.id==m.record.id})?.serverVersion ?? 0
                if m.attemptBase==nil{try store.updateMutation(m.id,base:base)}
                let recordJSON=try JSONSerialization.jsonObject(with:store.encoder.encode(m.record))
                let body=try JSONSerialization.data(withJSONObject:["record":recordJSON,"mutationId":m.id,"baseVersion":base])
                do{let ack:RecordAcknowledgement=try await request("/api/records",method:"POST",data:body);try store.acknowledge(m,version:ack.version)}
                catch NetworkProblem.response(let status,let text) where status==409{try store.updateMutation(m.id,error:text);blocked.insert(m.record.id)}
            }
            let pending=store.state.assets.filter{!$0.uploaded}
            for (index,asset) in pending.enumerated(){message="Передача файла \(index+1) из \(pending.count)";try await upload(asset,store:store)}
            message=blocked.isEmpty ? "Материалы приняты сервером" : "Материалы переданы; \(blocked.count) конфликтов требуют проверки"
        }catch{message="Передача приостановлена. \(error.localizedDescription). Очередь сохранена."}
    }
    func upload(_ asset:AssetEntry,store:AppStore)async throws {
        guard let file=store.assetURL(asset.id) else{throw CocoaError(.fileReadNoSuchFile)}
        let body=try JSONSerialization.data(withJSONObject:["id":asset.id,"projectId":asset.projectId,"sha256":asset.sha256,"size":asset.size,"mime":asset.mime])
        var status:UploadState=try await request("/api/uploads",method:"POST",data:body)
        try status.validate(asset)
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
        while status.offset<status.size{
            try Task.checkCancellation();try handle.seek(toOffset:UInt64(status.offset))
            guard let part=try handle.read(upToCount:min(1024*1024,status.size-status.offset)),!part.isEmpty else{throw CocoaError(.fileReadCorruptFile)}
            let expected=status.offset+part.count
            status=try await request("/api/uploads/\(asset.id)",method:"PATCH",data:part,headers:["Content-Type":"application/octet-stream","Upload-Offset":String(status.offset)])
            try status.validate(asset,expectedOffset:expected)
            progress=Double(status.offset)/Double(status.size)
        }
        let final:UploadState=try await request("/api/uploads/\(asset.id)/complete",method:"POST",data:Data("{}".utf8))
        try final.validate(asset,expectedOffset:asset.size)
        guard final.complete==1 else{throw NetworkProblem.response(409,"Файл ещё не подтверждён")};try store.uploaded(asset.id)
    }
    private func assemblyKey(_ project:FieldProject)->String{"assembly-job:"+baseURL+":"+project.id}
    private func followAssembly(_ id:String,project:FieldProject)async throws{
        while true{
            try Task.checkCancellation()
            let job:AssemblyJob=try await request("/api/jobs/"+id);assemblyJob=job;progress=job.progress ?? 0;message=job.message ?? "Сборка на сервере"
            UserDefaults.standard.set(id,forKey:assemblyKey(project))
            if job.state=="succeeded"{
                let list:AssemblyList=try await request("/api/assemblies?projectId="+project.id)
                guard let result=list.assemblies.first(where:{$0.id==job.assemblyId}) else{throw NetworkProblem.response(404,"Результат сборки пока недоступен")}
                assembly=result;message="Совмещено: \(result.registered.count). На проверку: \(result.pending.count).";return
            }
            if job.state=="failed" || job.state=="cancelled"{message=job.error ?? job.message ?? "Сборка остановлена; исходники сохранены";return}
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
    }
    func assemble(project:FieldProject,store:AppStore)async {
        guard !busy else{return}
        let ids=store.state.scans.filter{$0.projectId==project.id}.map(\.assetId)
        guard !ids.isEmpty else{message="Нет фрагментов для сборки";return}
        busy=true;defer{busy=false}
        do{
            let body=try JSONSerialization.data(withJSONObject:["projectId":project.id,"chunks":ids])
            let job:AssemblyJob=try await request("/api/assembly-jobs",method:"POST",data:body)
            UserDefaults.standard.set(job.id,forKey:assemblyKey(project));try await followAssembly(job.id,project:project)
        }catch{message="Проверка сборки приостановлена. Задание сохранено: \(error.localizedDescription)"}
    }
    func resumeAssembly(project:FieldProject)async{
        guard !busy,let id=UserDefaults.standard.string(forKey:assemblyKey(project)) else{return};busy=true;defer{busy=false}
        do{try await followAssembly(id,project:project)}catch{message="Не удалось проверить сборку. Задание сохранено."}
    }
    func cancelAssembly()async{
        guard let job=assemblyJob else{return}
        do{let updated:AssemblyJob=try await request("/api/assembly-jobs/"+job.id+"/cancel",method:"POST",data:Data("{}".utf8));assemblyJob=updated;message=updated.message ?? "Останавливаем сборку"}catch{message=error.localizedDescription}
    }
    func recognize(_ observation:Observation,project:FieldProject,store:AppStore)async {
        reading=nil
        guard let photo=observation.photos.first(where:{$0.role=="inscription"}),let asset=store.state.assets.first(where:{$0.id==photo.id}) else{message="Сначала снимите надпись";return}
        do{
            let _:FieldProject=try await request("/api/projects",method:"POST",data:store.encoder.encode(project))
            if !asset.uploaded{try await upload(asset,store:store)}
            let cacheKey="ocr:"+observation.id+":"+asset.id
            var previous:OCRJob?
            if let cached=UserDefaults.standard.data(forKey:cacheKey),let saved=try? JSONDecoder().decode(OCRJob.self,from:cached){
                do{previous=try await request("/api/jobs/\(saved.id)")}catch NetworkProblem.response(let code,_) where code==404{previous=nil}
            }
            if let previous,!["failed","blocked"].contains(previous.state){reading=previous;message=previous.error ?? "Сохранённое задание чтения";return}
            let queued=OCRJob(id:UUID().uuidString,recordId:observation.id,assetId:asset.id,sourceHash:asset.sha256,state:"queued")
            UserDefaults.standard.set(try JSONEncoder().encode(queued),forKey:cacheKey)
            let body=try JSONSerialization.data(withJSONObject:["id":queued.id,"assetId":asset.id,"projectId":project.id,"recordId":observation.id])
            let job:OCRJob=try await request("/api/ocr",method:"POST",data:body);reading=job
            UserDefaults.standard.set(try JSONEncoder().encode(job),forKey:cacheKey)
            message=job.error ?? "Задание чтения создано"
        }catch{message="Чтение пока недоступно: \(error.localizedDescription)"}
    }
    func refreshReading()async{guard let reading else{return};do{self.reading=try await request("/api/jobs/\(reading.id)")}catch{message=error.localizedDescription}}
}
