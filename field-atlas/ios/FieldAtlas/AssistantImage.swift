import UIKit
import ImageIO
import UniformTypeIdentifiers

struct AssistantImage {
    let data:Data
    let sourceHash:String
    let originalHash:String
    var transformed:Bool{sourceHash != originalHash}
    static func prepare(_ original:Data,hash:String,maxBytes:Int=6*1024*1024)throws->AssistantImage {
        guard maxBytes>0,maxBytes<=6*1024*1024,original.count<=100_000_000,SiteTransfer.digest(original)==hash,
              let source=CGImageSourceCreateWithData(original as CFData,nil),let raw=CGImageSourceGetType(source) else{throw CocoaError(.fileReadCorruptFile)}
        if [UTType.jpeg.identifier,UTType.png.identifier].contains(raw as String),original.count<=maxBytes{return AssistantImage(data:original,sourceHash:hash,originalHash:hash)}
        for size in [4096,3200,2400,1600] {
            let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:size,kCGImageSourceShouldCacheImmediately:true]
            guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else{throw CocoaError(.fileReadCorruptFile)}
            for quality in [0.94,0.85,0.72] {
                if let data=UIImage(cgImage:image).jpegData(compressionQuality:quality),data.count<=maxBytes{return AssistantImage(data:data,sourceHash:SiteTransfer.digest(data),originalHash:hash)}
            }
        }
        throw SiteTransferError.message("Не удалось подготовить читаемую копию для x0. Оригинал сохранён; попробуйте отдельный крупный план надписи.")
    }
}
