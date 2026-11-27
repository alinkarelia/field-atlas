import SwiftUI
import ImageIO
import FieldCore

struct MemorialNamesView:View {
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) private var dismiss
    let photos:[PhotoAttachment];let existing:[PersonReading];let onAdd:([PersonReading])->Void
    @State private var selected=Set<String>()
    @State private var candidates:[Candidate]=[]
    @State private var skipped:[NameReadingEvidence]=[]
    @State private var busy=false
    @State private var message=""
    @State private var source:SourcePreview?
    @State private var job:Task<Void,Never>?
    struct Candidate:Identifiable {let id=UUID();var person:PersonReading;var selected:Bool;let duplicate:Bool}
    private struct SourcePreview:Identifiable{let id=UUID();let evidence:NameReadingEvidence}
    private var chosen:[Candidate]{candidates.filter{$0.selected && !$0.person.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}}
    var body:some View{NavigationStack{List{
        Section{
            Text("Снимите надписи крупными фрагментами с небольшим перекрытием. За один проход можно обработать до 12 фотографий. LiDAR для чтения имён не используется.").font(.footnote)
            Text("Результат — черновики чтения. Даты сохраняются как на памятнике; значение дат рождения и смерти уточняется отдельно.").font(.footnote).foregroundStyle(.secondary)
        }
        if candidates.isEmpty{Section("Фрагменты памятника"){
            ForEach(Array(photos.enumerated()),id:\.element.id){index,photo in Toggle("Фрагмент \(index+1)",isOn:Binding(get:{selected.contains(photo.id)},set:{if $0{selected.insert(photo.id)}else{selected.remove(photo.id)}})).disabled(busy)}
            Button("Считать список имён"){recognize()}.disabled(busy || selected.isEmpty || selected.count>12).accessibilityIdentifier("memorial-recognize")
        }}
        if busy{Section{ProgressView(message);Button("Остановить"){job?.cancel()}}}
        else if !message.isEmpty{Section{Text(message).font(.footnote)}}
        if !candidates.isEmpty{Section("Предложения: \(candidates.count) · выбрано: \(chosen.count)"){
            ForEach($candidates){$candidate in VStack(alignment:.leading,spacing:10){
                Toggle("Добавить строку",isOn:$candidate.selected)
                TextField("Имя как на памятнике",text:$candidate.person.name).accessibilityIdentifier("memorial-name")
                if let dates=candidate.person.datesText,!dates.isEmpty{Text("Даты на плите: "+dates).font(.footnote)}
                HStack{TextField("Рождение · если понятно",text:$candidate.person.birth);TextField("Смерть · если понятно",text:$candidate.person.death)}.font(.subheadline)
                if candidate.duplicate{Text("Похожее имя уже встречалось. Проверьте, это повторный снимок или другой человек.").font(.caption).foregroundStyle(.orange)}
                if let evidence=candidate.person.evidence?.first{Button("Сверить с фотографией"){source=SourcePreview(evidence:evidence)}.font(.footnote);Text(evidence.text).font(.caption).foregroundStyle(.secondary)}
            }.padding(.vertical,7)}
        }}
        if !skipped.isEmpty{Section{DisclosureGroup("Неразобранные строки: \(skipped.count)"){ForEach(Array(skipped.enumerated()),id:\.offset){_,row in Button{source=SourcePreview(evidence:row)}label:{Text(row.text).font(.footnote).foregroundStyle(.primary)}}}}}
    }.navigationTitle("Имена с памятника").navigationBarTitleDisplayMode(.inline).toolbar{Button("Закрыть"){job?.cancel();dismiss()}}
        .safeAreaInset(edge:.bottom){if !candidates.isEmpty{VStack{if existing.count+chosen.count>2000{Text("Выбрано больше 2 000 имён для одной карточки. Снимите часть отметок и сохраните остальные в следующей карточке этого объекта.").font(.caption)};Button("Добавить \(chosen.count) черновиков"){onAdd(chosen.map(\.person));dismiss()}.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || busy || existing.count+chosen.count>2000).accessibilityIdentifier("memorial-import")}.padding().frame(maxWidth:.infinity).background(.regularMaterial)}}
    }.onAppear{if selected.isEmpty{selected=Set(photos.prefix(12).map(\.id))}}.onDisappear{job?.cancel()}
        .sheet(item:$source){value in NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){
            if let file=store.assetURL(value.evidence.photoID),let image=UIImage(contentsOfFile:file.path){Image(uiImage:image).resizable().scaledToFit().overlay{GeometryReader{proxy in let b=value.evidence.box;if b.count==4{Rectangle().stroke(.orange,lineWidth:3).frame(width:b[2]*proxy.size.width,height:b[3]*proxy.size.height).position(x:(b[0]+b[2]/2)*proxy.size.width,y:(1-b[1]-b[3]/2)*proxy.size.height)}}}}
            Text(value.evidence.text).textSelection(.enabled);Text("Рамка показывает строку, предложенную OCR. Сверьте буквы с оригиналом.").font(.footnote).foregroundStyle(.secondary)
        }.padding()}.navigationTitle("Источник чтения").toolbar{Button("Готово"){source=nil}}}}
    }
    private func recognize(){
        busy=true;candidates=[];skipped=[];let queue=photos.filter{selected.contains($0.id)}
        job=Task{defer{busy=false;job=nil};do{
            var known=Set(existing.map{MemorialNameParser.normalize($0.name)})
            for (index,photo) in queue.enumerated(){
                try Task.checkCancellation();message="Читаем фрагмент \(index+1) из \(queue.count)…"
                guard let file=store.assetURL(photo.id),let source=CGImageSourceCreateWithURL(file as CFURL,nil)else{throw CocoaError(.fileReadCorruptFile)}
                let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096]
                guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary)else{throw CocoaError(.fileReadCorruptFile)}
                let lines=try await LocalOCR.lines(image);try Task.checkCancellation()
                for line in lines{
                    let evidence=NameReadingEvidence(photoID:photo.id,sha256:photo.sha256,text:line.text,confidence:line.confidence,box:line.box)
                    if let person=MemorialNameParser.suggestion(evidence){let key=MemorialNameParser.normalize(person.name);let duplicate=known.contains(key);known.insert(key);candidates.append(Candidate(person:person,selected:!duplicate,duplicate:duplicate))}else{skipped.append(evidence)}
                }
            }
            message=candidates.isEmpty ? "Подходящие строки не найдены. Проверьте неразобранные строки или снимите надпись ближе.":"Проверьте имена. Все добавленные строки останутся непроверенными чтениями с привязкой к фотографии."
        }catch is CancellationError{message="Чтение остановлено. Полученные предложения сохранены в этом окне."}catch{message=error.localizedDescription}}
    }
}
