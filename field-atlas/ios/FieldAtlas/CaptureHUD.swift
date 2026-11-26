import SwiftUI

/// The live camera has no text panels. Instructions and results open only on request.
struct CaptureTool: View {
    let symbol: String
    let label: String
    let id: String
    var active = false
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.black.opacity(0.68))
                Circle().stroke(active ? Color.yellow : Color.white.opacity(0.38), lineWidth: active ? 2.5 : 1)
                if busy { ProgressView().tint(.white) }
                else if symbol == "x0" { Text("x0").font(.system(size:20,weight:.bold,design:.rounded)) }
                else { Image(systemName: symbol).font(.system(size:21,weight:.medium)) }
            }.foregroundStyle(active ? .yellow : .white).frame(width:48,height:48).contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
            .accessibilityValue(active ? "Включено" : "")
    }
}

struct CaptureHUD<Left:View,Right:View>: View {
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    var body: some View {
        HStack(alignment:.center) {
            VStack(spacing:8,content:left)
            Spacer(minLength:24)
            VStack(spacing:8,content:right)
        }.padding(.horizontal,12).padding(.vertical,8)
        .frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

struct CaptureHelp: View {
    @Environment(\.dismiss) private var dismiss
    let title:String
    let status:String
    let items:[(String,String,String)]
    var body: some View {
        NavigationStack {
            List {
                Section("Сейчас") { Text(status).textSelection(.enabled) }
                Section("Инструменты") {
                    ForEach(items.indices,id:\.self) { i in
                        Label { VStack(alignment:.leading,spacing:6) { Text(items[i].1).font(.headline); Text(items[i].2).font(.subheadline).foregroundStyle(.secondary) } }
                        icon: { if items[i].0 == "x0" {Text("x0").bold()} else {Image(systemName:items[i].0)} }
                        .padding(.vertical,4)
                    }
                }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("К камере") {dismiss()} }
        }
    }
}
