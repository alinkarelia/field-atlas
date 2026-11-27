import SwiftUI
import FieldCore

struct PersonalPackageProgress:Decodable {
    let id:String;let projectID:String;let revision:String;let state:String
    let chunkSize:Int;let assets:[SiteAssetProgress];let url:String
    let identifiers:FieldIdentityCodes?
}

@MainActor final class PersonalFieldTransfer:ObservableObject {
    @Published private(set) var busy=false
    @Published private(set) var progress=0.0
    @Published private(set) var message="Карточки и оригиналы сохранятся в вашем личном разделе сайта. Задание не требуется."
    @Published private(set) var receiptURL:URL?
    private var operation:Task<Void,Never>?
    private var owner:String?
    func cancel(){operation?.cancel()}
    func start(project:FieldProject,store:AppStore,account:WebsiteAccount){
        guard !busy else{return};busy=true;progress=0;receiptURL=nil
        operation=Task{defer{busy=false;operation=nil;owner=nil};do{try await send(project,store:store,account:account)}catch is CancellationError{message="Передача приостановлена. Можно продолжить с принятой части."}catch{message=error.localizedDescription+" Исходники сохранены на устройстве."}}
    }
    private func request(_ path:String,method:String="GET",body:Data?=nil,binary:Bool=false,account:WebsiteAccount)async throws->Data{
        guard account.context?.user.id==owner,path.hasPrefix("/api/field-work"),!path.contains(".."),let url=URL(string:"https://archiverf.ru"+path)else{throw StaffAccountError.accountExpired}
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body;request.timeoutInterval=120
        request.setValue("Bearer "+(try account.accountToken()),forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if body != nil{request.setValue(binary ? "application/octet-stream":"application/json",forHTTPHeaderField:"Content-Type")}
        var attempt=0
        while true{
        try Task.checkCancellation();let(data,response)=try await TeamHTTP.session.data(for:request);try Task.checkCancellation()
        guard account.context?.user.id==owner,let http=response as? HTTPURLResponse,http.url==url,data.count<=8*1024*1024 else{throw StaffAccountError.invalidResponse}
        if http.statusCode==429,attempt<3{
            attempt+=1;let delay=min(65,max(1,Double(http.value(forHTTPHeaderField:"Retry-After") ?? "") ?? 60))
            message="Сервер попросил паузу. Передача продолжится автоматически…"
            try await Task.sleep(for:.seconds(delay));continue
        }
        guard (200..<300).contains(http.statusCode)else{
            let detail=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            if let text=detail?["detail"] as? String,text.count<=1000{throw SiteTransferError.message(text)}
            throw StaffAccountError.http(http.statusCode)
        };return data
        }
    }
    private func send(_ project:FieldProject,store:AppStore,account:WebsiteAccount)async throws{
        guard let uid=account.context?.user.id,!project.synthetic else{throw SiteTransferError.message("Войдите на сайт. Учебные проекты не отправляются.")};owner=uid
        struct Snapshot:Encodable{let schema="field-atlas-snapshot-v1";let project:FieldProject;let records:[Observation];let scans:[ScanReference];let origin:GeoOrigin?}
        let assets=store.state.assets.filter{$0.projectId==project.id}.sorted{$0.id<$1.id}
        let snapshot=try store.encoder.encode(Snapshot(project:project,records:store.records(project.id),scans:store.state.scans.filter{$0.projectId==project.id},origin:store.state.origins[project.id]))
        let revision=SiteTransfer.digest(snapshot)
        guard let snapshotText=String(data:snapshot,encoding:.utf8)else{throw StaffAccountError.invalidResponse}
        let manifest:[String:Any]=["projectID":project.id,"revision":revision,"snapshot":snapshotText,"assets":assets.map{["id":$0.id,"filename":$0.filename,"mime":$0.mime,"size":$0.size,"sha256":$0.sha256] as [String:Any]}]
        message="Проверяем личное хранилище…"
        let initial=try JSONDecoder().decode(PersonalPackageProgress.self,from:await request("/api/field-work",method:"POST",body:JSONSerialization.data(withJSONObject:manifest),account:account))
        guard initial.projectID==project.id,initial.revision==revision,initial.id.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,(1...1024*1024).contains(initial.chunkSize),initial.assets.count==assets.count,Set(initial.assets.map(\.id)).count==assets.count else{throw StaffAccountError.invalidResponse}
        let path="/api/field-work/"+initial.id
        let total=Double(max(1,assets.reduce(0){$0+$1.size}));var finished=0
        for (index,asset) in assets.enumerated(){
            try Task.checkCancellation()
            guard var status=initial.assets.first(where:{$0.id==asset.id})else{throw StaffAccountError.invalidResponse}
            try status.validate(id:asset.id,size:asset.size)
            if !status.verified {
                guard let file=store.assetURL(asset.id)else{throw CocoaError(.fileReadNoSuchFile)}
                let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
                guard try handle.seekToEnd()==UInt64(asset.size)else{throw CocoaError(.fileReadCorruptFile)}
                while status.uploadedBytes<asset.size {
                    try Task.checkCancellation();try handle.seek(toOffset:UInt64(status.uploadedBytes))
                    guard let bytes=try handle.read(upToCount:min(initial.chunkSize,asset.size-status.uploadedBytes)),!bytes.isEmpty else{throw CocoaError(.fileReadCorruptFile)}
                    message="Передаём файл \(index+1) из \(assets.count)";let next=status.uploadedBytes+bytes.count
                    status=try JSONDecoder().decode(SiteAssetProgress.self,from:await request(path+"/assets/"+asset.id+"?offset=\(status.uploadedBytes)",method:"PUT",body:bytes,binary:true,account:account))
                    try status.validate(id:asset.id,size:asset.size,offset:next);progress=Double(finished+next)/total
                }
                message="Проверяем оригинал \(index+1) из \(assets.count)…"
                let verified=try JSONDecoder().decode(SiteAssetProgress.self,from:await request(path+"/assets/"+asset.id+"/verify",method:"POST",body:Data("{}".utf8),account:account))
                try verified.validate(id:asset.id,size:asset.size,offset:asset.size);guard verified.verified else{throw StaffAccountError.invalidResponse}
            }
            finished+=asset.size;progress=Double(finished)/total
        }
        let done=try JSONDecoder().decode(PersonalPackageProgress.self,from:await request(path+"/complete",method:"POST",body:Data("{}".utf8),account:account))
        guard done.id==initial.id,done.projectID==project.id,done.revision==revision,done.state=="complete",done.assets.count==assets.count,done.assets.allSatisfy(\.verified),done.url=="https://archiverf.ru/static/fieldwork/index.html#"+initial.id else{throw StaffAccountError.invalidResponse}
        // The local receipt is owner-specific. It never changes sandbox or task-upload flags.
        let receipt=try JSONSerialization.data(withJSONObject:["ownerID":uid,"projectID":project.id,"revision":revision,"url":done.url,"originals":assets.count,"state":"complete"])
        try receipt.write(to:store.root.appendingPathComponent("personal-receipt-"+SiteTransfer.digest(Data((uid+project.id).utf8))+".json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        if let codes=done.identifiers{try store.saveIdentityCodes(codes,projectID:project.id)}
        receiptURL=URL(string:done.url);progress=1;message="Проект принят в ваш личный раздел: \(assets.count) оригиналов и снимок карточек. Другим пользователям он не опубликован."
    }
}

struct PersonalFieldTransferSection:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var account:WebsiteAccount
    @EnvironmentObject var transfer:PersonalFieldTransfer
    let project:FieldProject?
    var body:some View{Section("Свой проект · без задания"){
        if let project{
            Text(project.title).font(.headline)
            Text(transfer.message).font(.footnote).accessibilityIdentifier("personal-transfer-status")
            if account.context != nil{Button("Отправить свой проект"){transfer.start(project:project,store:store,account:account)}.disabled(transfer.busy || project.synthetic).accessibilityIdentifier("personal-transfer-start")}
            else{Text("Войдите в учётную запись сайта выше. Назначение от руководителя не требуется.").font(.footnote)}
            if transfer.busy{ProgressView(value:transfer.progress);Button("Приостановить"){transfer.cancel()}}
            if let url=transfer.receiptURL{Link("Открыть принятый проект на сайте",destination:url)}
        }else{Text("Откройте свой проект и нажмите кнопку передачи. Задание для самостоятельной работы не требуется.")}
        Link("Мои полевые проекты на сайте",destination:URL(string:"https://archiverf.ru/static/fieldwork/index.html")!)
    }}
}
