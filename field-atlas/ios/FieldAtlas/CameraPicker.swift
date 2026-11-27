import SwiftUI
import UIKit
import Vision

struct CameraPicker:UIViewControllerRepresentable {
    var source:UIImagePickerController.SourceType = .camera
    var completed:(UIImage?)->Void
    func makeCoordinator()->Coordinator{Coordinator(completed:completed)}
    func makeUIViewController(context:Context)->UIImagePickerController{
        let picker=UIImagePickerController();picker.sourceType=UIImagePickerController.isSourceTypeAvailable(source) ? source : .photoLibrary;picker.delegate=context.coordinator;picker.allowsEditing=false;return picker
    }
    func updateUIViewController(_ uiViewController:UIImagePickerController,context:Context){}
    final class Coordinator:NSObject,UINavigationControllerDelegate,UIImagePickerControllerDelegate{
        var completed:(UIImage?)->Void
        init(completed:@escaping(UIImage?)->Void){self.completed=completed}
        func imagePickerControllerDidCancel(_ picker:UIImagePickerController){completed(nil)}
        func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]){completed(info[.originalImage] as? UIImage)}
    }
}
enum LocalOCR {
    struct Line {let text:String;let confidence:Double;let box:[Double]}
    static func read(_ image:CGImage)async throws->String{
        try await lines(image).map(\.text).joined(separator:"\n")
    }
    static func lines(_ image:CGImage)async throws->[Line]{
        try await withCheckedThrowingContinuation{continuation in
            DispatchQueue.global(qos:.userInitiated).async{
                do{
                    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
                    let supported=try request.supportedRecognitionLanguages();let selected=["ru-RU","en-US"].filter{supported.contains($0)}
                    guard selected.contains("ru-RU") else{throw NSError(domain:"FieldOCR",code:1,userInfo:[NSLocalizedDescriptionKey:"Кириллица недоступна в локальном OCR этой системы. Используйте x0 или ручное чтение."])}
                    request.recognitionLanguages=selected;request.usesLanguageCorrection=false
                    try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
                    let rows=(request.results ?? []).compactMap{observation->Line? in guard let value=observation.topCandidates(1).first else{return nil};let b=observation.boundingBox;return Line(text:value.string,confidence:Double(value.confidence),box:[b.minX,b.minY,b.width,b.height])}
                    continuation.resume(returning:rows)
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
}
