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
    static func read(_ image:CGImage)async throws->String{
        try await withCheckedThrowingContinuation{continuation in
            DispatchQueue.global(qos:.userInitiated).async{
                do{
                    let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
                    let supported=try request.supportedRecognitionLanguages();let selected=["ru-RU","en-US"].filter{supported.contains($0)}
                    guard selected.contains("ru-RU") else{throw NSError(domain:"FieldOCR",code:1,userInfo:[NSLocalizedDescriptionKey:"Кириллица недоступна в локальном OCR этой системы. Используйте x0 или ручное чтение."])}
                    request.recognitionLanguages=selected;request.usesLanguageCorrection=false
                    try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
                    continuation.resume(returning:(request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n"))
                }catch{continuation.resume(throwing:error)}
            }
        }
    }
}
