import SwiftUI
import FieldCore

struct TerritoryView:View {
    @ObservedObject var territory:TerritoryStore
    var onSelect:(TerritoryPlace)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var theme="all"
    @State private var period="all"
    @State private var query=""
    var body:some View {
        NavigationStack {List {
            if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {Section("Карта без связи") {
                Text(territory.catalog?.title ?? "Карта недоступна").font(.headline)
                Text(territory.message).font(.subheadline).accessibilityIdentifier("territory-status")
                DisclosureGroup("О сохранённой карте") {
                if let catalog=territory.catalog {
                    Text("Версия "+catalog.revision).font(.caption)
                    Text(catalog.coverage).font(.caption).foregroundStyle(.secondary)
                    Text(catalog.attribution).font(.caption2)
                }
                if territory.busy{Button("Остановить обновление"){territory.cancel()}}
                else{Button("Обновить с сайта"){territory.update()}.accessibilityIdentifier("territory-update")}
                }
            }}
            if let catalog=territory.catalog {
                Section("Места и истории") {
                    if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Picker("Тема",selection:$theme){Text("Все темы").tag("all");ForEach(catalog.themes){Text($0.title).tag($0.id)}}
                    Picker("Истории периода",selection:$period){Text("Все периоды").tag("all");ForEach(catalog.periods){Text($0.title).tag($0.id)}}
                    if period != "all"{Text(catalog.periodMeaning).font(.caption).foregroundStyle(.secondary)}
                    } else if theme != "all" || period != "all" {Button("Искать по всем темам и периодам"){theme="all";period="all"}}
                    let places=catalog.places.filter{$0.matches(theme:theme,period:period,query:query)}
                    Text("Найдено: \(places.count)").font(.caption).accessibilityIdentifier("territory-count")
                    ForEach(places){place in
                        Button {
                            onSelect(place)
                            dismiss()
                        } label: {
                            VStack(alignment:.leading,spacing:4) {
                                Text(place.name)
                                Text(place.locality).font(.caption).foregroundStyle(.secondary)
                                if place.approximate {
                                    Text("Приблизительное положение").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.disabled(place.point==nil).accessibilityIdentifier("territory-place-"+place.id)
                    }
                    if places.isEmpty{Text("Совпадений нет. Измените поиск или выберите все периоды.")}
                }
            }
        }.scrollDismissesKeyboard(.interactively).searchable(text:$query,placement:.navigationBarDrawer(displayMode:.always),prompt:"Место или деревня").navigationTitle("Карта и места").navigationBarTitleDisplayMode(.inline).toolbar{Button("Готово"){dismiss()}}}
    }
}

struct TerritoryPlaceView:View {
    let place:TerritoryPlace
    let onLocate:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {List {
            Section {Text(place.name).font(.title2.weight(.semibold));Text(place.locality).foregroundStyle(.secondary);Text(place.summary);if !place.status.isEmpty{Text(place.status)}}
            if place.approximate{Section{Text("Метка приблизительная. Она не определяет точные границы объекта.")}}
            Section {Button("Показать на карте"){onLocate();dismiss()};if let url=URL(string:place.url){Link("Открыть карточку сайта",destination:url)}}
            if !place.sources.isEmpty{Section("Источники карточки"){ForEach(place.sources,id:\.self){Text($0).font(.subheadline)}}}
        }.navigationTitle("Место в атласе").navigationBarTitleDisplayMode(.inline).toolbar{Button("Закрыть"){dismiss()}}}
    }
}
