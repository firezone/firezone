//
//  LogCompressor.swift
//
//
//  Created by Jamil Bou Kheir on 3/28/24.
//

import AppleArchive
import Foundation
import System

/// Utility for creating an AAR archive given a Set of input URLs.
///
/// The URLs are read in parallel, compressed, and chunked back via the provided completionHandler.
///
/// The format provided to the completionHandler is:
///
public struct LogCompressor {

  public struct Chunk: Codable {
    var nextChunk: Bool
    var data: Data
  }

  public static func compress(_ url: URL) {

    // Define header keys
    guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")
    else {
      Log.app.error("\(#function): Couldn't define header keys")

      return
    }

    do {
        guard let filePath = FilePath(url) else {
          Log.app.error("\(#function): Invalid file path: \(url)")

          return
        }

        try encodeStream.writeDirectoryContents(
          archiveFrom: filePath,
          keySet: keySet
        )
    } catch {
      Log.app.error("Write file entry failed: \(error)")
      return nil
    }

    return fileURL
}
