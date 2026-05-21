import Foundation
import ImageIO

/// 读取图片像素尺寸的轻量工具。
/// `CGImageSource` 只解析图片容器的头部元数据，不把像素数据解码进内存——
/// 一张 4000×3000 的图全解码约 48MB，而这里只读几百字节文件头，开销接近零，
/// 因此即便走文件 IO 也适合在采集路径和 backfill 里同步调用。
enum ImageDimensions {
    /// 读取图片文件的像素宽高；文件缺失 / 格式无法识别时返回 nil。
    static func read(at path: String) -> (width: Int32, height: Int32)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return (Int32(width), Int32(height))
    }
}
