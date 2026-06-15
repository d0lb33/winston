//
//  saveAndLoadImages.swift
//  winston
//
//  Created by Igor Marcossi on 07/09/23.
//

import Foundation
import UIKit

func saveImage(image: UIImage) -> String? {
  guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
  
  let id = UUID().uuidString
//  let fileName = id
  var data: Data?
  var ext: String?
  if let newData = image.jpegData(compressionQuality: 1) {
    data = newData
    ext = "jpg"
  }
  if let newData = image.pngData() {
    data = newData
    ext = "png"
  }
  guard let data = data, let ext = ext else { return nil }
  
  let fileURL = documentsDirectory.appendingPathComponent("\(id).\(ext)")
  
  //Checks if file exists, removes it if so.
  if FileManager.default.fileExists(atPath: fileURL.path) {
    do {
      try FileManager.default.removeItem(atPath: fileURL.path)
//      print("Removed old image")
    } catch let removeError {
      print("couldn't remove file at path", removeError)
    }
  }
  
  do {
    try data.write(to: fileURL)
    return "\(id).\(ext)"
  } catch let error {
    print("error saving file with error", error)
    return nil
  }
}


func loadImage(fileName: String) -> UIImage? {
  let documentDirectory = FileManager.SearchPathDirectory.documentDirectory
  
  let userDomainMask = FileManager.SearchPathDomainMask.userDomainMask
  let paths = NSSearchPathForDirectoriesInDomains(documentDirectory, userDomainMask, true)
  
  if let dirPath = paths.first {
    let imageUrl = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName)
    let image = UIImage(contentsOfFile: imageUrl.path)
    return image
  }
  
  return nil
}

func loadImageURL(fileName: String) -> URL? {
  let documentDirectory = FileManager.SearchPathDirectory.documentDirectory
  
  let userDomainMask = FileManager.SearchPathDomainMask.userDomainMask
  let paths = NSSearchPathForDirectoriesInDomains(documentDirectory, userDomainMask, true)
  
  if let dirPath = paths.first {
    let imageUrl = URL(fileURLWithPath: dirPath).appendingPathComponent(fileName)
    return imageUrl
  }
  
  return nil
}
