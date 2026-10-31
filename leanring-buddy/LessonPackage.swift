//
//  LessonPackage.swift
//  leanring-buddy
//
//  Reads and writes `.clicky` files: a zip holding lesson.json, images/ and
//  voice/. A single file is what survives being emailed or sent in a message.
//
//  A `.clicky` file comes from another person, so opening one treats it as
//  untrusted: entries are checked before anything is extracted, and every file
//  name inside lesson.json has to resolve to a plain file in the package.
//  Lessons never run anything. They only say what to point at and what to say.
//

import Foundation

struct LessonPackageError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// A lesson opened from disk, unpacked into a temporary directory.
struct LessonPackage {
    let lesson: ClickyLesson
    /// Where lesson.json and its files were unpacked.
    let unpackedDirectoryURL: URL
    /// The size of the `.clicky` file itself, for the share card.
    let archiveSizeInBytes: Int
    let archiveURL: URL

    func imageData(forFileName fileName: String?) -> Data? {
        guard let fileName else { return nil }
        return LessonPackageFiles.contents(
            ofFileNamed: fileName,
            inDirectoryNamed: ClickyLesson.imagesDirectoryName,
            under: unpackedDirectoryURL
        )
    }

    func voiceClipURL(forFileName fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return LessonPackageFiles.existingFileURL(
            ofFileNamed: fileName,
            inDirectoryNamed: ClickyLesson.voiceDirectoryName,
            under: unpackedDirectoryURL
        )
    }
}

enum LessonPackageFiles {
    /// A file name from lesson.json is only honoured if it's a single path
    /// component, which stops a crafted lesson reaching outside its package.
    static func existingFileURL(ofFileNamed fileName: String, inDirectoryNamed directoryName: String, under packageDirectoryURL: URL) -> URL? {
        guard isPlainFileName(fileName) else { return nil }
        let fileURL = packageDirectoryURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    static func contents(ofFileNamed fileName: String, inDirectoryNamed directoryName: String, under packageDirectoryURL: URL) -> Data? {
        guard let fileURL = existingFileURL(ofFileNamed: fileName, inDirectoryNamed: directoryName, under: packageDirectoryURL) else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    static func isPlainFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && !fileName.contains("/")
            && !fileName.contains("\\")
            && fileName != "."
            && fileName != ".."
    }
}

enum LessonPackageArchiver {
    private static let dittoExecutableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let unzipExecutableURL = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Far above any real lesson, and it stops a zip bomb filling the disk.
    private static let maximumUnpackedSizeInBytes = 100 * 1024 * 1024
    private static let allowedFileExtensions: Set<String> = ["json", "jpg", "jpeg", "png", "m4a"]

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Zips a directory holding lesson.json into a `.clicky` file. The temporary
    /// file means a crash mid-write can't leave a half-written lesson behind.
    static func writeArchive(fromDirectoryAt packageDirectoryURL: URL, to archiveURL: URL) throws {
        let temporaryArchiveURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporaryArchiveURL) }

        try runProcess(
            executableURL: dittoExecutableURL,
            arguments: ["-c", "-k", "--norsrc", "--noextattr", packageDirectoryURL.path, temporaryArchiveURL.path]
        )

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: temporaryArchiveURL, to: archiveURL)
    }

    /// Validates a `.clicky` file and unpacks it into a fresh temporary directory.
    static func openArchive(at archiveURL: URL) throws -> LessonPackage {
        let listingOutput = try runProcess(
            executableURL: unzipExecutableURL,
            arguments: ["-l", archiveURL.path]
        )
        try validateArchiveListing(listingOutput)

        let unpackedDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-lesson-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unpackedDirectoryURL, withIntermediateDirectories: true)

        try runProcess(
            executableURL: dittoExecutableURL,
            arguments: ["-x", "-k", archiveURL.path, unpackedDirectoryURL.path]
        )

        do {
            try validateUnpackedFiles(in: unpackedDirectoryURL)

            let manifestURL = unpackedDirectoryURL.appendingPathComponent(ClickyLesson.manifestFileName)
            guard let manifestData = try? Data(contentsOf: manifestURL) else {
                throw LessonPackageError(message: "this file has no lesson.json inside, so it isn't a clicky lesson.")
            }

            let lesson: ClickyLesson
            do {
                lesson = try makeDecoder().decode(ClickyLesson.self, from: manifestData)
            } catch {
                throw LessonPackageError(message: "this lesson file is damaged: \(error.localizedDescription)")
            }

            guard lesson.formatVersion == 1 else {
                throw LessonPackageError(message: "this lesson was made by a newer clicky (format \(lesson.formatVersion)).")
            }
            guard !lesson.steps.isEmpty else {
                throw LessonPackageError(message: "this lesson has no steps.")
            }

            let archiveAttributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
            return LessonPackage(
                lesson: lesson,
                unpackedDirectoryURL: unpackedDirectoryURL,
                archiveSizeInBytes: (archiveAttributes[.size] as? Int) ?? 0,
                archiveURL: archiveURL
            )
        } catch {
            try? FileManager.default.removeItem(at: unpackedDirectoryURL)
            throw error
        }
    }

    /// Writes an updated lesson.json back into a `.clicky` file, keeping the
    /// images and voice clips. Used to record what a replay really cost.
    static func rewriteLesson(_ updatedLesson: ClickyLesson, in lessonPackage: LessonPackage) throws {
        let manifestData = try makeEncoder().encode(updatedLesson)
        let manifestURL = lessonPackage.unpackedDirectoryURL.appendingPathComponent(ClickyLesson.manifestFileName)
        try manifestData.write(to: manifestURL, options: .atomic)
        try writeArchive(fromDirectoryAt: lessonPackage.unpackedDirectoryURL, to: lessonPackage.archiveURL)
    }

    /// Checks `unzip -l` output before extraction. The listing's last column
    /// is the entry name, and the size is its first.
    static func validateArchiveListing(_ listingOutput: String) throws {
        var totalUnpackedSizeInBytes = 0

        for listingLine in listingOutput.split(separator: "\n").map(String.init) {
            let columns = listingLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 4,
                  let entrySizeInBytes = Int(columns[0]),
                  columns[1].contains("-"),
                  columns[2].contains(":") else {
                continue
            }

            let entryName = columns[3...].joined(separator: " ")
            totalUnpackedSizeInBytes += entrySizeInBytes

            let pathComponents = entryName.split(separator: "/").map(String.init)
            if entryName.hasPrefix("/") || pathComponents.contains("..") {
                throw LessonPackageError(message: "this lesson file tries to write outside its own folder, so clicky won't open it.")
            }
        }

        if totalUnpackedSizeInBytes > maximumUnpackedSizeInBytes {
            throw LessonPackageError(message: "this lesson file is far too big to be a real lesson, so clicky won't open it.")
        }
    }

    /// The listing can't see symlinks, so they're caught after extraction,
    /// before anything reads through one.
    private static func validateUnpackedFiles(in unpackedDirectoryURL: URL) throws {
        let propertyKeys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard let fileEnumerator = FileManager.default.enumerator(at: unpackedDirectoryURL, includingPropertiesForKeys: propertyKeys) else {
            return
        }

        for case let fileURL as URL in fileEnumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(propertyKeys))
            if resourceValues.isSymbolicLink == true {
                throw LessonPackageError(message: "this lesson file contains a link to somewhere else on the disk, so clicky won't open it.")
            }
            if resourceValues.isRegularFile == true,
               !allowedFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                throw LessonPackageError(message: "this lesson file contains something that isn't part of a lesson (\(fileURL.lastPathComponent)), so clicky won't open it.")
            }
        }
    }

    @discardableResult
    private static func runProcess(executableURL: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()
        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LessonPackageError(message: "\(executableURL.lastPathComponent) failed: \(errorText)")
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
