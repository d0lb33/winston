//
//  saveMedia.swift
//  winston
//
//  Created by Igor Marcossi on 12/07/23.
//

import Foundation
import Photos
import UIKit
import Nuke

enum MediaType: Equatable {
    case image
    case video
}

func saveMedia(_ urlString: String, _ mediaType: MediaType, _ completion: ((Bool) -> ())? = nil) {
    guard let url = URL(string: urlString) else {
      completion?(false)
      return
    }

    if mediaType == .video {
      saveVideoMedia(url, completion)
      return
    }

    PHPhotoLibrary.shared().performChanges({
        switch mediaType {
        case .image:
            if let imageData = try? Data(contentsOf: url),
               let image = UIImage(data: imageData) {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        case .video:
            break
        }
    }) { saved, error in
        if saved {
          completion?(true)
            print("\(mediaType) saved successfully")
        } else if let error = error {
          completion?(false)
            print("Error saving \(mediaType): \(error)")
        } else {
          completion?(false)
            print("Unknown error occurred")
        }
    }
}

private func saveVideoMedia(_ url: URL, _ completion: ((Bool) -> ())? = nil) {
  guard isDirectVideoDownloadURL(url) else {
    completion?(false)
    print("Unsupported video stream URL for saving: \(url.absoluteString)")
    return
  }

  if url.isFileURL {
    saveLocalVideo(url, completion)
    return
  }

  URLSession.shared.downloadTask(with: url) { tempURL, _, error in
    guard error == nil, let tempURL else {
      completion?(false)
      print("Error downloading video: \(error?.localizedDescription ?? "unknown")")
      return
    }

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)

    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: tempURL, to: destination)
      saveLocalVideo(destination) { saved in
        try? FileManager.default.removeItem(at: destination)
        completion?(saved)
      }
    } catch {
      completion?(false)
      print("Error preparing video for saving: \(error)")
    }
  }.resume()
}

private func saveLocalVideo(_ url: URL, _ completion: ((Bool) -> ())? = nil) {
  PHPhotoLibrary.shared().performChanges({
    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
  }) { saved, error in
    if saved {
      completion?(true)
      print("video saved successfully")
    } else if let error {
      completion?(false)
      print("Error saving video: \(error)")
    } else {
      completion?(false)
      print("Unknown error occurred")
    }
  }
}

private func isDirectVideoDownloadURL(_ url: URL) -> Bool {
  let ext = url.pathExtension.lowercased()
  guard !["m3u8", "mpd"].contains(ext) else { return false }
  return ["mp4", "mov", "m4v", "webm"].contains(ext) || url.isFileURL
}

func downloadAndSaveImage(url: URL) async throws -> Data? {
  let image = try? await ImagePipeline.shared.image(for: url)
  if (image != nil){
    let data = image!.jpegData(compressionQuality: 1.0)
    return data
  }
  
  return nil
}
