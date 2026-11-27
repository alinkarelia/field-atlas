import SwiftUI

enum SurveyFeature:String,CaseIterable,Identifiable {
    case entrance,tree,dump,container,obstacle,anomaly,sector,plot
    var id:String{rawValue}
    var title:String{switch self{case .entrance:return "Вход";case .tree:return "Дерево";case .dump:return "Свалка";case .container:return "Мусорный контейнер";case .obstacle:return "Препятствие";case .anomaly:return "Углубление / возможное захоронение";case .sector:return "Сектор кладбища";case .plot:return "Участок захоронений"}}
    var symbol:String{switch self{case .entrance:return "door.left.hand.open";case .tree:return "tree.fill";case .dump:return "exclamationmark.triangle.fill";case .container:return "trash.fill";case .obstacle:return "hand.raised.fill";case .anomaly:return "questionmark.diamond.fill";case .sector:return "square.grid.2x2";case .plot:return "square.dashed"}}
}

struct SurveyAction:View {
    let title:String
    let detail:String
    let symbol:String
    var action:()->Void
    var body:some View {
        Button(action:action){HStack(spacing:14){Image(systemName:symbol).font(.title3).frame(width:28);VStack(alignment:.leading,spacing:5){Text(title).font(.headline);Text(detail).font(.subheadline).foregroundStyle(.secondary)};Spacer(minLength:8);Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)}.padding(.vertical,7).contentShape(Rectangle())}.buttonStyle(.plain)
    }
}
