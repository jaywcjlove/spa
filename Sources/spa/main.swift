import Foundation

let version = "0.1.1"

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

struct Arguments {
    let repositoryURL: String
    let version: String?
}

func printHelp() {
    print("""
    spa - Swift Package Add

    Usage:
      spa <github-url> [version]

    Examples:
      spa https://github.com/user/repo
      spa https://github.com/user/repo 1.2.3

    Options:
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

    guard args.count == 1 || args.count == 2 else {
        throw CLIError(description: "Invalid arguments. Run `spa --help` for usage.")
    }

    let repositoryURL = args[0]
    guard repositoryURL.hasPrefix("https://github.com/") || repositoryURL.hasPrefix("git@github.com:") else {
        throw CLIError(description: "Only GitHub repository URLs are supported.")
    }

    return Arguments(repositoryURL: repositoryURL, version: args.count == 2 ? args[1] : nil)
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
        guard let idRange = contents.range(of: "\n\t\t\(id) ") else {
            return nil
        }
        return rangeOfObject(containing: idRange.upperBound)
    }

    private func rangeOfObject(containing index: String.Index) -> Range<String.Index>? {
        let prefix = contents[..<index]
        guard let start = prefix.range(of: "\n\t\t", options: .backwards)?.lowerBound else {
            return nil
        }

        guard let endRange = contents.range(of: "\n\t\t};", range: index..<contents.endIndex) else {
            return nil
        }

        return start..<endRange.upperBound
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

    try editor.addPackage(repositoryURL: arguments.repositoryURL, version: arguments.version)
    try editor.contents.write(to: project.pbxprojURL, atomically: true, encoding: .utf8)

    let requirement = arguments.version.map { "version \($0)" } ?? "branch main"
    print("Added \(inferProductName(from: arguments.repositoryURL)) (\(requirement)) to \(project.xcodeprojURL.lastPathComponent).")
} catch {
    fputs("spa: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
