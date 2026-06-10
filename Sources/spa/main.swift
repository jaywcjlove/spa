import Foundation

let version = "0.1.6"

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

enum Command {
    case add(repositoryURL: String, version: String?)
    case remove(packageName: String)
}

struct Arguments {
    let command: Command
}

func printHelp() {
    print("""
    spa - Swift Package Add

    Usage:
      spa <github-url> [version]
      spa -r <package-name>

    Examples:
      spa https://github.com/user/repo
      spa https://github.com/user/repo 1.2.3
      spa -r Alamofire

    Options:
      -r, --remove <package-name> Remove a package dependency
      -h, --help      Show this help
      -v, --version   Show version
    """)
}

func parseArguments(_ rawArguments: [String]) throws -> Arguments? {
    let args = Array(rawArguments.dropFirst())

    if args.isEmpty || args.contains("-h") || args.contains("--help") {
        printHelp()
        return nil
    }

    if args.count == 1, args[0] == "-v" || args[0] == "--version" {
        print("spa \(version)")
        return nil
    }

    if args.count == 2, args[0] == "-r" || args[0] == "--remove" {
        return Arguments(command: .remove(packageName: args[1]))
    }

    guard args.count == 1 || args.count == 2 else {
        throw CLIError(description: "Invalid arguments. Run `spa --help` for usage.")
    }

    let repositoryURL = args[0]
    guard repositoryURL.hasPrefix("https://github.com/") || repositoryURL.hasPrefix("git@github.com:") else {
        throw CLIError(description: "Only GitHub repository URLs are supported.")
    }

    return Arguments(command: .add(repositoryURL: repositoryURL, version: args.count == 2 ? args[1] : nil))
}

struct ProjectSelection {
    let xcodeprojURL: URL
    let pbxprojURL: URL
}

func findProject(in directory: URL) throws -> ProjectSelection {
    let contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    let projects = contents
        .filter { $0.pathExtension == "xcodeproj" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    guard let project = projects.first else {
        throw CLIError(description: "No .xcodeproj found in \(directory.path). Run spa from your Xcode project directory.")
    }

    if projects.count > 1 {
        print("Found multiple .xcodeproj files. Using \(project.lastPathComponent).")
    }

    let pbxproj = project.appendingPathComponent("project.pbxproj")
    guard FileManager.default.fileExists(atPath: pbxproj.path) else {
        throw CLIError(description: "Missing project.pbxproj inside \(project.lastPathComponent).")
    }

    return ProjectSelection(xcodeprojURL: project, pbxprojURL: pbxproj)
}

struct XcodeProjectEditor {
    var contents: String

    mutating func addPackage(repositoryURL: String, version: String?) throws {
        if contents.contains("repositoryURL = \(quote(repositoryURL));") ||
            contents.contains("repositoryURL = \"\(repositoryURL)\";") {
            throw CLIError(description: "Package already exists in project: \(repositoryURL)")
        }

        let productName = inferProductName(from: repositoryURL)
        let packageID = makeID()
        let productID = makeID()
        let buildFileID = makeID()

        try ensureSection(named: "XCRemoteSwiftPackageReference")
        try ensureSection(named: "XCSwiftPackageProductDependency")

        try insertBuildFile(id: buildFileID, productID: productID, productName: productName)
        try insertPackageReference(id: packageID, repositoryURL: repositoryURL, version: version)
        try insertProductDependency(id: productID, packageID: packageID, productName: productName, repositoryURL: repositoryURL)
        try appendToProjectPackageReferences(packageID: packageID, repositoryURL: repositoryURL)
        try appendToNativeTargetProductDependencies(productID: productID, productName: productName)
        try appendToFrameworksBuildPhase(buildFileID: buildFileID, productName: productName)
    }

    mutating func removePackage(named packageName: String) throws {
        var packageIDs = Set<String>()
        var productDependencies = [(productID: String, packageID: String, productName: String)]()

        if let packageReference = packageReference(named: packageName) {
            packageIDs.insert(packageReference)
        }

        if let productDependency = productDependency(named: packageName) {
            packageIDs.insert(productDependency.packageID)
            productDependencies.append(productDependency)
        }

        for packageID in packageIDs {
            productDependencies.append(contentsOf: productDependenciesReferencingPackage(id: packageID))
        }

        guard !packageIDs.isEmpty || !productDependencies.isEmpty else {
            throw CLIError(description: "Package not found in project: \(packageName)")
        }

        var idsToRemoveFromLists = packageIDs
        var buildFileIDs = Set<String>()
        for productDependency in productDependencies {
            idsToRemoveFromLists.insert(productDependency.productID)
            idsToRemoveFromLists.insert(productDependency.packageID)
            buildFileIDs.formUnion(
                buildFileIDsReferencingProduct(
                    id: productDependency.productID,
                    productName: productDependency.productName
                )
            )
        }

        idsToRemoveFromLists.formUnion(buildFileIDs)
        removeListLines(containing: idsToRemoveFromLists)
        for productDependency in productDependencies {
            removeObject(withID: productDependency.productID)
        }
        for packageID in packageIDs {
            removeObject(withID: packageID)
        }
        for buildFileID in buildFileIDs {
            removeObject(withID: buildFileID)
        }
        removePackageReferenceLines(named: packageName)
        removePackageReferenceObjects(named: packageName)
    }

    private mutating func ensureSection(named section: String) throws {
        guard !contents.contains("/* Begin \(section) section */") else {
            return
        }

        guard let index = contents.range(of: "/* End PBXProject section */")?.upperBound else {
            throw CLIError(description: "Could not find PBXProject section in project.pbxproj.")
        }

        let sectionText = """


    /* Begin \(section) section */
    /* End \(section) section */
"""
        contents.insert(contentsOf: sectionText, at: index)
    }

    private mutating func insertBuildFile(id: String, productID: String, productName: String) throws {
        let line = "\t\t\(id) /* \(productName) in Frameworks */ = {isa = PBXBuildFile; productRef = \(productID) /* \(productName) */; };\n"
        try insert(line, beforeEndOfSection: "PBXBuildFile")
    }

    private mutating func insertPackageReference(id: String, repositoryURL: String, version: String?) throws {
        let requirement: String
        if let version {
            requirement = """
{kind = upToNextMajorVersion; minimumVersion = \(version); }
"""
        } else {
            requirement = """
{branch = main; kind = branch; }
"""
        }

        let repoName = inferProductName(from: repositoryURL)
        let line = "\t\t\(id) /* XCRemoteSwiftPackageReference \"\(repoName)\" */ = {isa = XCRemoteSwiftPackageReference; repositoryURL = \(quote(repositoryURL)); requirement = \(requirement); };\n"
        try insert(line, beforeEndOfSection: "XCRemoteSwiftPackageReference")
    }

    private mutating func insertProductDependency(id: String, packageID: String, productName: String, repositoryURL: String) throws {
        let repoName = inferProductName(from: repositoryURL)
        let line = "\t\t\(id) /* \(productName) */ = {isa = XCSwiftPackageProductDependency; package = \(packageID) /* XCRemoteSwiftPackageReference \"\(repoName)\" */; productName = \(productName); };\n"
        try insert(line, beforeEndOfSection: "XCSwiftPackageProductDependency")
    }

    private mutating func appendToProjectPackageReferences(packageID: String, repositoryURL: String) throws {
        let repoName = inferProductName(from: repositoryURL)
        guard let projectRange = rangeOfObject(withISA: "PBXProject") else {
            throw CLIError(description: "Could not find PBXProject object.")
        }

        if let referencesRange = contents.range(of: "packageReferences = (", range: projectRange) {
            try append("\(packageID) /* XCRemoteSwiftPackageReference \"\(repoName)\" */", toListStartingAt: referencesRange.lowerBound)
        } else {
            try insertProperty(
                "packageReferences = (\n\t\t\t\t\(packageID) /* XCRemoteSwiftPackageReference \"\(repoName)\" */,\n\t\t\t);",
                intoObjectRange: projectRange
            )
        }
    }

    private mutating func appendToNativeTargetProductDependencies(productID: String, productName: String) throws {
        guard let targetRange = rangeOfFirstNativeTarget() else {
            throw CLIError(description: "Could not find a PBXNativeTarget.")
        }

        if let dependenciesRange = contents.range(of: "packageProductDependencies = (", range: targetRange) {
            try append("\(productID) /* \(productName) */", toListStartingAt: dependenciesRange.lowerBound)
        } else {
            try insertProperty(
                "packageProductDependencies = (\n\t\t\t\t\(productID) /* \(productName) */,\n\t\t\t);",
                intoObjectRange: targetRange
            )
        }
    }

    private mutating func appendToFrameworksBuildPhase(buildFileID: String, productName: String) throws {
        guard let targetRange = rangeOfFirstNativeTarget() else {
            throw CLIError(description: "Could not find a PBXNativeTarget.")
        }

        guard let frameworksRange = rangeOfFrameworksBuildPhase(forTargetRange: targetRange) else {
            throw CLIError(description: "Could not find PBXFrameworksBuildPhase for selected target.")
        }

        guard let filesRange = contents.range(of: "files = (", range: frameworksRange) else {
            throw CLIError(description: "Could not find files list in PBXFrameworksBuildPhase.")
        }

        try append("\(buildFileID) /* \(productName) in Frameworks */", toListStartingAt: filesRange.lowerBound)
    }

    private mutating func insert(_ text: String, beforeEndOfSection section: String) throws {
        guard let endRange = contents.range(of: "\t/* End \(section) section */") ??
            contents.range(of: "/* End \(section) section */") else {
            throw CLIError(description: "Could not find \(section) section.")
        }

        contents.insert(contentsOf: text, at: endRange.lowerBound)
    }

    private func packageReference(named packageName: String) -> String? {
        var searchStart = contents.startIndex

        while let isaRange = contents.range(
            of: "isa = XCRemoteSwiftPackageReference;",
            range: searchStart..<contents.endIndex
        ) {
            guard let objectRange = rangeOfObjectOrLine(containing: isaRange.lowerBound) else {
                searchStart = isaRange.upperBound
                continue
            }

            if packageReference(in: objectRange, matches: packageName),
               let packageID = objectID(in: objectRange) {
                return packageID
            }

            searchStart = isaRange.upperBound
        }

        return nil
    }

    private func productDependency(named productName: String) -> (productID: String, packageID: String, productName: String)? {
        var searchStart = contents.startIndex
        let productPattern = #"productName = "?\#(NSRegularExpression.escapedPattern(for: productName))"?;"#

        while let productNameRange = contents.range(
            of: productPattern,
            options: [.regularExpression, .caseInsensitive],
            range: searchStart..<contents.endIndex
        ) {
            guard let objectRange = rangeOfObjectOrLine(containing: productNameRange.lowerBound),
                  contents.range(of: "isa = XCSwiftPackageProductDependency;", range: objectRange) != nil,
                  let productID = objectID(in: objectRange),
                  let packageID = firstMatch(in: objectRange, pattern: #"package = ([A-F0-9]{24})"#) else {
                searchStart = productNameRange.upperBound
                continue
            }

            return (productID, packageID, productName)
        }

        return nil
    }

    private func productDependenciesReferencingPackage(id packageID: String) -> [(productID: String, packageID: String, productName: String)] {
        var dependencies: [(productID: String, packageID: String, productName: String)] = []
        var searchStart = contents.startIndex
        let packagePattern = #"package = \#(packageID)\b"#

        while let packageRange = contents.range(
            of: packagePattern,
            options: .regularExpression,
            range: searchStart..<contents.endIndex
        ) {
            if let objectRange = rangeOfObjectOrLine(containing: packageRange.lowerBound),
               contents.range(of: "isa = XCSwiftPackageProductDependency;", range: objectRange) != nil,
               let productID = objectID(in: objectRange),
               let productName = productName(in: objectRange) {
                dependencies.append((productID, packageID, productName))
            }

            searchStart = packageRange.upperBound
        }

        return dependencies
    }

    private func buildFileIDsReferencingProduct(id productID: String, productName: String) -> Set<String> {
        var ids = Set<String>()
        var searchStart = contents.startIndex
        let productRefPattern = #"productRef = \#(productID)\b"#

        while let productRefRange = contents.range(
            of: productRefPattern,
            options: .regularExpression,
            range: searchStart..<contents.endIndex
        ) {
            if let objectRange = rangeOfObjectOrLine(containing: productRefRange.lowerBound),
               contents.range(of: "isa = PBXBuildFile;", range: objectRange) != nil,
               let buildFileID = objectID(in: objectRange) {
                ids.insert(buildFileID)
            }
            searchStart = productRefRange.upperBound
        }

        searchStart = contents.startIndex
        let commentPattern = #"/\* \#(NSRegularExpression.escapedPattern(for: productName)) in Frameworks \*/"#
        while let commentRange = contents.range(
            of: commentPattern,
            options: .regularExpression,
            range: searchStart..<contents.endIndex
        ) {
            if let lineRange = lineRange(containing: commentRange.lowerBound),
               let id = firstMatch(in: lineRange, pattern: #"([A-F0-9]{24})"#) {
                ids.insert(id)
            }
            searchStart = commentRange.upperBound
        }

        return ids
    }

    private mutating func removeListLines(containing ids: Set<String>) {
        guard !ids.isEmpty else {
            return
        }

        var searchStart = contents.startIndex
        while searchStart < contents.endIndex {
            guard let idRange = contents.range(
                of: #"[A-F0-9]{24}"#,
                options: .regularExpression,
                range: searchStart..<contents.endIndex
            ) else {
                break
            }

            let id = String(contents[idRange])
            guard ids.contains(id), let lineRange = lineRange(containing: idRange.lowerBound) else {
                searchStart = idRange.upperBound
                continue
            }

            let line = contents[lineRange]
            if line.contains("/*") && line.contains("*/,") {
                contents.removeSubrange(lineRange)
                searchStart = lineRange.lowerBound
            } else {
                searchStart = idRange.upperBound
            }
        }
    }

    private mutating func removeObject(withID id: String) {
        guard let objectRange = rangeOfObjectOrLine(withID: id) else {
            return
        }
        contents.removeSubrange(objectRange)
    }

    private mutating func removePackageReferenceLines(named packageName: String) {
        var searchStart = contents.startIndex
        let escapedName = NSRegularExpression.escapedPattern(for: packageName)
        let pattern = #"XCRemoteSwiftPackageReference\s+"\#(escapedName)""#

        while let matchRange = contents.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive],
            range: searchStart..<contents.endIndex
        ) {
            guard let lineRange = lineRange(containing: matchRange.lowerBound) else {
                searchStart = matchRange.upperBound
                continue
            }

            let line = contents[lineRange]
            if line.contains("*/,") {
                contents.removeSubrange(lineRange)
                searchStart = lineRange.lowerBound
            } else {
                searchStart = matchRange.upperBound
            }
        }
    }

    private mutating func removePackageReferenceObjects(named packageName: String) {
        var searchStart = contents.startIndex
        let escapedName = NSRegularExpression.escapedPattern(for: packageName)
        let patterns = [
            #"XCRemoteSwiftPackageReference\s+"\#(escapedName)""#,
            #"repositoryURL = "?[^;"]*[/:\s]\#(escapedName)(\.git)?"?;"#
        ]

        while searchStart < contents.endIndex {
            var nextMatch: Range<String.Index>?
            for pattern in patterns {
                if let match = contents.range(
                    of: pattern,
                    options: [.regularExpression, .caseInsensitive],
                    range: searchStart..<contents.endIndex
                ), nextMatch == nil || match.lowerBound < nextMatch!.lowerBound {
                    nextMatch = match
                }
            }

            guard let matchRange = nextMatch else {
                break
            }

            guard let objectRange = rangeOfObjectOrLine(containing: matchRange.lowerBound),
                  contents.range(of: "isa = XCRemoteSwiftPackageReference;", range: objectRange) != nil else {
                searchStart = matchRange.upperBound
                continue
            }

            contents.removeSubrange(objectRange)
            searchStart = objectRange.lowerBound
        }
    }

    private mutating func append(_ value: String, toListStartingAt start: String.Index) throws {
        guard let closeIndex = findListCloseIndex(startingAt: start) else {
            throw CLIError(description: "Could not find end of list in project.pbxproj.")
        }

        contents.insert(contentsOf: "\t\t\t\t\(value),\n", at: closeIndex)
    }

    private mutating func insertProperty(_ property: String, intoObjectRange objectRange: Range<String.Index>) throws {
        guard let closeRange = contents.range(of: "\n\t\t};", range: objectRange) else {
            throw CLIError(description: "Could not find end of object in project.pbxproj.")
        }

        contents.insert(contentsOf: "\n\t\t\t\(property)", at: closeRange.lowerBound)
    }

    private func findListCloseIndex(startingAt start: String.Index) -> String.Index? {
        guard let openingParen = contents[start...].firstIndex(of: "(") else {
            return nil
        }

        var depth = 0
        var index = openingParen
        while index < contents.endIndex {
            let character = contents[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = contents.index(after: index)
        }

        return nil
    }

    private func rangeOfObject(withISA isa: String) -> Range<String.Index>? {
        guard let isaRange = contents.range(of: "isa = \(isa);") else {
            return nil
        }
        return rangeOfObject(containing: isaRange.lowerBound)
    }

    private func rangeOfFirstNativeTarget() -> Range<String.Index>? {
        guard let targetRange = contents.range(of: "isa = PBXNativeTarget;") else {
            return nil
        }
        return rangeOfObject(containing: targetRange.lowerBound)
    }

    private func rangeOfFrameworksBuildPhase(forTargetRange targetRange: Range<String.Index>) -> Range<String.Index>? {
        guard let buildPhasesRange = contents.range(of: "buildPhases = (", range: targetRange),
              let listClose = findListCloseIndex(startingAt: buildPhasesRange.lowerBound) else {
            return nil
        }

        var cursor = buildPhasesRange.upperBound
        while cursor < listClose {
            guard let idRange = contents.range(
                of: #"[A-F0-9]{24}"#,
                options: .regularExpression,
                range: cursor..<listClose
            ) else {
                break
            }

            if let objectRange = rangeOfObject(withID: String(contents[idRange])),
               contents.range(of: "isa = PBXFrameworksBuildPhase;", range: objectRange) != nil {
                return objectRange
            }

            cursor = idRange.upperBound
        }

        return nil
    }

    private func rangeOfObject(withID id: String) -> Range<String.Index>? {
        rangeOfObjectStarting(withID: id)
    }

    private func rangeOfObjectOrLine(withID id: String) -> Range<String.Index>? {
        guard let idRange = contents.range(
            of: #"\n[ \t]*\#(id)\b"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return rangeOfObjectStarting(withID: id) ?? lineRange(containing: idRange.upperBound)
    }

    private func rangeOfObjectOrLine(containing index: String.Index) -> Range<String.Index>? {
        if let objectRange = rangeOfObject(containing: index) {
            return objectRange
        }
        return lineRange(containing: index)
    }

    private func rangeOfObject(containing index: String.Index) -> Range<String.Index>? {
        let prefix = contents[..<index]
        guard let start = prefix.range(
            of: #"\n[ \t]*[A-F0-9]{24} /\*[^\n]*\*/ = \{"#,
            options: [.regularExpression, .backwards]
        )?.lowerBound else {
            return nil
        }

        guard let endRange = contents.range(of: "\n\t\t};", range: index..<contents.endIndex) else {
            return nil
        }

        return start..<endRange.upperBound
    }

    private func rangeOfObjectStarting(withID id: String) -> Range<String.Index>? {
        guard let startRange = contents.range(
            of: #"\n[ \t]*\#(id) /\*[^\n]*\*/ = \{"#,
            options: .regularExpression
        ) else {
            return nil
        }

        guard let endRange = contents.range(of: "\n\t\t};", range: startRange.upperBound..<contents.endIndex) else {
            return nil
        }

        return startRange.lowerBound..<endRange.upperBound
    }

    private func lineRange(containing index: String.Index) -> Range<String.Index>? {
        guard index < contents.endIndex else {
            return nil
        }

        let lineStart = contents[..<index].lastIndex(of: "\n").map { contents.index(after: $0) } ?? contents.startIndex
        let lineEnd = contents[index...].firstIndex(of: "\n").map { contents.index(after: $0) } ?? contents.endIndex
        return lineStart..<lineEnd
    }

    private func objectID(in range: Range<String.Index>) -> String? {
        firstMatch(in: range, pattern: #"([A-F0-9]{24}) /\*"#)
    }

    private func productName(in range: Range<String.Index>) -> String? {
        guard let rawName = firstMatch(in: range, pattern: #"productName = ("?[^";]+"?);"#) else {
            return nil
        }

        return rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func packageReference(in range: Range<String.Index>, matches packageName: String) -> Bool {
        let object = String(contents[range])
        let lowercasedObject = object.lowercased()
        let lowercasedName = packageName.lowercased()
        if lowercasedObject.contains(#"xcremoteswiftpackagereference "\#(lowercasedName)""#) ||
            lowercasedObject.contains("/\(lowercasedName).git") ||
            lowercasedObject.contains("/\(lowercasedName);") ||
            lowercasedObject.contains("/\(lowercasedName)\"") {
            return true
        }

        let escapedName = NSRegularExpression.escapedPattern(for: packageName)
        let patterns = [
            #"XCRemoteSwiftPackageReference\s+"?\#(escapedName)"?"#,
            #"repositoryURL = "?[^;"]*[/:\s]\#(escapedName)(\.git)?"?;"#
        ]

        return patterns.contains { pattern in
            object.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func firstMatch(in range: Range<String.Index>, pattern: String) -> String? {
        guard let range = contents.range(of: pattern, options: .regularExpression, range: range) else {
            return nil
        }

        let match = String(contents[range])
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: match, range: NSRange(match.startIndex..., in: match)),
              result.numberOfRanges > 1,
              let captureRange = Range(result.range(at: 1), in: match) else {
            return match
        }

        return String(match[captureRange])
    }
}

func makeID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).uppercased()
}

func inferProductName(from repositoryURL: String) -> String {
    var name = repositoryURL
    if let slash = name.lastIndex(of: "/") {
        name = String(name[name.index(after: slash)...])
    }
    if let colon = name.lastIndex(of: ":") {
        name = String(name[name.index(after: colon)...])
    }
    if name.hasSuffix(".git") {
        name.removeLast(4)
    }
    return name
}

func quote(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:@"))
    if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
}

do {
    guard let arguments = try parseArguments(CommandLine.arguments) else {
        exit(EXIT_SUCCESS)
    }

    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let project = try findProject(in: currentDirectory)
    var editor = XcodeProjectEditor(contents: try String(contentsOf: project.pbxprojURL, encoding: .utf8))

    switch arguments.command {
    case let .add(repositoryURL, packageVersion):
        try editor.addPackage(repositoryURL: repositoryURL, version: packageVersion)
        try editor.contents.write(to: project.pbxprojURL, atomically: true, encoding: .utf8)

        let requirement = packageVersion.map { "version \($0)" } ?? "branch main"
        print("Added \(inferProductName(from: repositoryURL)) (\(requirement)) to \(project.xcodeprojURL.lastPathComponent).")
    case let .remove(packageName):
        try editor.removePackage(named: packageName)
        try editor.contents.write(to: project.pbxprojURL, atomically: true, encoding: .utf8)
        print("Removed \(packageName) from \(project.xcodeprojURL.lastPathComponent).")
    }
} catch {
    fputs("spa: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
