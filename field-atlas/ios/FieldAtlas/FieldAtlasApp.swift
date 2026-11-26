import SwiftUI
import FieldCore

enum Palette {
    static let green=Color(red:0.13,green:0.31,blue:0.24)
    static let paper=Color(red:0.96,green:0.97,blue:0.95)
    static let ink=Color(red:0.09,green:0.18,blue:0.15)
}
@main struct FieldAtlasApp:App {
    @StateObject private var store=AppStore()
    @StateObject private var sync=SyncClient()
    @StateObject private var account=WebsiteAccount()
    @StateObject private var siteTransfer=SiteTransfer()
    @StateObject private var workLocation=WebsiteWorkLocation()
    @StateObject private var missions=FieldMissionRecorder()
    @Environment(\.scenePhase) private var phase
    var body:some Scene{WindowGroup{launchContent.environmentObject(store).environmentObject(sync).environmentObject(account).environmentObject(siteTransfer).environmentObject(workLocation).environmentObject(missions).tint(Palette.green).preferredColorScheme(.light)
        .onAppear{missions.configure(store)}
        .onChange(of:phase){_,value in if value != .active{workLocation.stop(reason:"background");siteTransfer.cancel()}}
        .onChange(of:account.hasSavedLogin){_,value in if !value{workLocation.stop(reason:"logout");siteTransfer.cancel()}}
    }}
    @ViewBuilder private var launchContent:some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FIELD_ATLAS_UI_HARNESS"] == "camera",ProcessInfo.processInfo.environment["FIELD_ATLAS_TEST_SESSION"] != nil{CaptureLayoutHarness()}else{ProjectHome()}
        #else
        ProjectHome()
        #endif
    }
}
struct ProjectHome:View {
    @EnvironmentObject var store:AppStore
    @State private var selected:FieldProject?
    @State private var creating:ProjectKind?
    @State private var title=""
    @State private var showTransfer=false
    @State private var showAccount=false
    var body:some View {
        Group{
            if let selected{WorkspaceView(project:selected,onBack:{self.selected=nil})}
            else{
                NavigationStack{
                    ScrollView{
                        VStack(alignment:.leading,spacing:24){
                            VStack(alignment:.leading,spacing:10){Text("ВАШИ ПОЛЕВЫЕ ИССЛЕДОВАНИЯ").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary);Text("Каждое место.\nВ своей системе.").font(.system(size:34,weight:.semibold,design:.rounded));Text("Выберите тип проекта. Съёмки, карточки и инструменты будут соответствовать вашей задаче.").foregroundStyle(.secondary)}
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:155),spacing:12)],spacing:12){ForEach(ProjectKind.allCases){kind in
                                Button{title="";creating=kind}label:{VStack(alignment:.leading,spacing:20){Image(systemName:kind.symbol).font(.title2);VStack(alignment:.leading,spacing:6){Text(kind.title).font(.headline);Text(kind.subtitle).font(.caption).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity,minHeight:150,alignment:.leading).padding(18).background(.white,in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).stroke(.gray.opacity(0.18)))}.buttonStyle(.plain).accessibilityIdentifier("project-kind-"+kind.rawValue)
                            }}
                            Text("Мои проекты").font(.title2.weight(.semibold))
                            if store.state.projects.isEmpty{ContentUnavailableView("Первый проект",systemImage:"map",description:Text("Создайте его выше. Работа сохраняется на устройстве."))}
                            ForEach(store.state.projects){project in Button{selected=project}label:{HStack(spacing:16){Image(systemName:project.type.symbol).font(.title3);VStack(alignment:.leading,spacing:4){Text(project.title).font(.headline);Text(project.type.title).font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"chevron.right")}.padding(.vertical,14).contentShape(Rectangle())}.buttonStyle(.plain);Divider()}
                        }.padding(20).frame(maxWidth:900)
                    }.background(Palette.paper).navigationTitle("Полевой атлас").navigationBarTitleDisplayMode(.inline)
                    .toolbar{
                        ToolbarItem(placement:.topBarLeading){Button{showAccount=true}label:{Image(systemName:"person.crop.circle")}.accessibilityLabel("Учётная запись сайта").accessibilityIdentifier("website-account")}
                        ToolbarItem(placement:.topBarTrailing){Button{showTransfer=true}label:{Image(systemName:"icloud.and.arrow.up")}.accessibilityLabel("Передача материалов")}
                    }
                }
            }
        }
        .sheet(item:$creating){kind in NavigationStack{Form{Section(kind.title){TextField("Название проекта",text:$title).accessibilityIdentifier("project-title");Text(kind.subtitle).foregroundStyle(.secondary)};Section{Text("Материалы этого проекта будут храниться отдельно.").font(.footnote)}}.navigationTitle("Новый проект").toolbar{ToolbarItem(placement:.cancellationAction){Button("Отмена"){creating=nil}};ToolbarItem(placement:.confirmationAction){Button("Создать"){do{let p=FieldProject(title:title.trimmingCharacters(in:.whitespacesAndNewlines),type:kind);try store.addProject(p);selected=p;creating=nil}catch{store.error=error.localizedDescription}}.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("project-create")}}}}
        .sheet(isPresented:$showTransfer){TransferView(project:nil)}
        .sheet(isPresented:$showAccount){WebsiteAccountView()}
        .alert("Не удалось выполнить операцию",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("Понятно"){store.error=nil}}message:{Text(store.error ?? "")}
    }
}

struct TransferView:View {
    @EnvironmentObject var store:AppStore
    @EnvironmentObject var sync:SyncClient
    @Environment(\.dismiss) var dismiss
    @AppStorage("serverURL") private var serverURL=""
    @State private var showAccount=false
    let project:FieldProject?
    var body:some View{
        NavigationStack{Form{
            Section("Семейный архив"){Button("Учётная запись сайта"){showAccount=true}}
            WebsiteWorkLocationSection()
            SiteTransferSection(project:project)
            Section("Локальная песочница · дополнительно"){TextField("https://…",text:$serverURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL);Text("Для разработки и испытаний собственного сервера. Передача на сайт находится выше и не требует ввода адреса.").font(.footnote)}
            Section("На устройстве"){LabeledContent("Изменений карточек",value:String(store.state.outbox.count));LabeledContent("Файлов к отправке",value:String(store.state.assets.filter{!$0.uploaded}.count));Text(sync.message).font(.footnote);if sync.busy{ProgressView(value:sync.progress)}}
            Section{Button("Передать в песочницу"){Task{await sync.synchronize(store)}}.disabled(sync.busy||serverURL.isEmpty);if let project{Button("Собрать фрагменты в песочнице"){Task{await sync.assemble(project:project,store:store)}}.disabled(sync.busy||serverURL.isEmpty)}}
            if let job=sync.assemblyJob,["queued","running","cancelling"].contains(job.state),job.projectId==project?.id{Section{Button("Остановить сборку"){Task{await sync.cancelAssembly()}}.disabled(job.state=="cancelling")}}
            if let a=sync.assembly,a.projectId==project?.id{Section("Результат сборки"){LabeledContent("Совмещено",value:String(a.registered.count));ForEach(a.pending,id:\.id){item in Text(item.reason).foregroundStyle(.orange)}}}
            if store.state.outbox.contains(where:{$0.state=="conflict"}){Section("Требуют проверки"){ForEach(store.state.outbox.filter{$0.state=="conflict"}){m in VStack(alignment:.leading){Text(m.record.title);Text(m.error ?? "Конфликт версии").font(.caption).foregroundStyle(.secondary)}}}}
            Section{Text("Передача возобновляется после следующего запуска. Исходные файлы не удаляются автоматически и доступны в приложении «Файлы».").font(.footnote)}
        }.navigationTitle("Передача").task{if let project{await sync.resumeAssembly(project:project)}}.toolbar{ToolbarItem(placement:.confirmationAction){Button("Готово"){dismiss()}}}.sheet(isPresented:$showAccount){WebsiteAccountView()}}
    }
}
