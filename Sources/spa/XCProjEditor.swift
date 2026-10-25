import Foundation

struct XCProjEditor {
    var contents: String

    mutating func addPackage(repositoryURL: String, version: String?) throws {
        guard let root = rootObjectRange() else {
            throw CLIError(description: "Could not parse project.xcproj.")
        }

        if packageAlreadyExists(repositoryURL, in: root) {
            throw CLIError(description: "Package already exists in project: \(repositoryURL)")
        }

        guard let targets = valueRange(for: "targets", in: root), contents[targets.lowerBound] == "[" else {
            throw CLIError(description: "Could not find a native target.")
        }
        guard let target = firstNativeTarget(in: targets) else {
            throw CLIError(description: "Could not find a native target.")
        }
        guard hasFrameworksBuildPhase(in: target) else {
            throw CLIError(description: "Could not find a frameworks build phase for the selected target.")
        }

        let packageName = inferProductName(from: repositoryURL)
        try insertRemotePackage(repositoryURL: repositoryURL, version: version, in: root)
        guard let root = rootObjectRange(),
              let targets = valueRange(for: "targets", in: root),
              let target = firstNativeTarget(in: targets) else {
            throw CLIError(description: "Could not find a native target.")
        }
        try insertPackageProductMember(packageName: packageName, productName: packageName, in: target)
    }

    mutating func removePackage(named packageName: String) throws {
        guard rootObjectRange() != nil else {
            throw CLIError(description: "Could not parse project.xcproj.")
        }

        var ranges = rangesMatchingPackage(named: packageName)
        guard !ranges.isEmpty else {
            throw CLIError(description: "Package not found in project: \(packageName)")
        }

        ranges.sort { $0.lowerBound > $1.lowerBound }
        for range in ranges {
            removeObject(range)
        }

        removeEmptyArrays(named: ["packages", "package-product-members", "dependencies"])
    }

    private func packageAlreadyExists(_ repositoryURL: String, in root: Range<String.Index>) -> Bool {
        guard let packages = valueRange(for: "packages", in: root), contents[packages.lowerBound] == "[" else {
            return false
        }
        let wanted = canonicalRepository(repositoryURL)
        for object in objectRanges(in: packages) {
            guard let repository = stringValue(for: "repository", in: object) else {
                continue
            }
            if canonicalRepository(repository) == wanted {
                return true
            }
        }
        return false
    }

    private mutating func insertRemotePackage(repositoryURL: String, version: String?, in root: Range<String.Index>) throws {
        let object = remotePackageObject(repositoryURL: repositoryURL, version: version)
        if let packages = valueRange(for: "packages", in: root), contents[packages.lowerBound] == "[" {
            try append(object, toArray: packages)
            return
        }

        guard let anchor = keyTokenRange(for: "files", in: root) ?? keyTokenRange(for: "targets", in: root) else {
            throw CLIError(description: "Could not find a place to insert packages in project.xcproj.")
        }
        let lineStart = lineStartIndex(containing: anchor.lowerBound)
        let keyIndent = indentation(of: lineStart)
        let itemIndent = deeper(keyIndent)
        let rendered = render(object, indent: itemIndent)
        let block = "\(keyIndent)\"packages\": [\n\(rendered),\n\(keyIndent)],\n"
        contents.insert(contentsOf: block, at: lineStart)
    }

    private mutating func insertPackageProductMember(packageName: String, productName: String, in target: Range<String.Index>) throws {
        let object = packageProductMemberObject(packageName: packageName, productName: productName)
        if let members = valueRange(for: "package-product-members", in: target), contents[members.lowerBound] == "[" {
            try append(object, toArray: members)
            return
        }

        guard let phases = valueRange(for: "build-phases", in: target) else {
            throw CLIError(description: "Could not find a frameworks build phase for the selected target.")
        }
        let keyIndent = indentation(of: lineStartIndex(containing: phases.lowerBound))
        let itemIndent = deeper(keyIndent)
        let rendered = render(object, indent: itemIndent)
        let block = "\n\(keyIndent)\"package-product-members\": [\n\(rendered),\n\(keyIndent)],"
        insertPropertyBlock(block, after: phases)
    }

    private func rangesMatchingPackage(named packageName: String) -> [Range<String.Index>] {
        guard let root = rootObjectRange() else {
            return []
        }

        var ranges: [Range<String.Index>] = []
        if let packages = valueRange(for: "packages", in: root), contents[packages.lowerBound] == "[" {
            for object in objectRanges(in: packages) where packageReference(object, matches: packageName) {
                ranges.append(object)
            }
        }

        guard let targets = valueRange(for: "targets", in: root), contents[targets.lowerBound] == "[" else {
            return ranges
        }

        for target in objectRanges(in: targets) {
            if let members = valueRange(for: "package-product-members", in: target), contents[members.lowerBound] == "[" {
                for object in objectRanges(in: members) where productReference(object, matches: packageName) {
                    ranges.append(object)
                }
            }
            if let dependencies = valueRange(for: "dependencies", in: target), contents[dependencies.lowerBound] == "[" {
                for object in objectRanges(in: dependencies) where dependencyReference(object, matches: packageName) {
                    ranges.append(object)
                }
            }
        }
        return ranges
    }

    private mutating func removeEmptyArrays(named keys: [String]) {
        var didRemove = true
        while didRemove {
            didRemove = false
            guard let root = rootObjectRange() else {
                return
            }
            if removeFirstEmptyArray(named: keys, in: root) {
                didRemove = true
                continue
            }
            guard let targets = valueRange(for: "targets", in: root), contents[targets.lowerBound] == "[" else {
                continue
            }
            for target in objectRanges(in: targets) where removeFirstEmptyArray(named: keys, in: target) {
                didRemove = true
                break
            }
        }
    }

    private mutating func removeFirstEmptyArray(named keys: [String], in object: Range<String.Index>) -> Bool {
        for key in keys {
            guard let value = valueRange(for: key, in: object),
                  contents[value.lowerBound] == "[",
                  arrayIsEmpty(value) else {
                continue
            }
            removeProperty(forKey: key, in: object)
            return true
        }
        return false
    }

    private func packageReference(_ object: Range<String.Index>, matches packageName: String) -> Bool {
        if let repository = stringValue(for: "repository", in: object),
           inferProductName(from: repository).caseInsensitiveCompare(packageName) == .orderedSame {
            return true
        }
        if let path = stringValue(for: "path", in: object) {
            let name = (path as NSString).lastPathComponent
            if name.caseInsensitiveCompare(packageName) == .orderedSame {
                return true
            }
        }
        return false
    }

    private func productReference(_ object: Range<String.Index>, matches packageName: String) -> Bool {
        if let package = stringValue(for: "package", in: object),
           package.caseInsensitiveCompare(packageName) == .orderedSame {
            return true
        }
        if let product = stringValue(for: "product-name", in: object),
           product.caseInsensitiveCompare(packageName) == .orderedSame {
            return true
        }
        return false
    }

    private func dependencyReference(_ object: Range<String.Index>, matches packageName: String) -> Bool {
        guard stringValue(for: "kind", in: object) == "package" else {
            return false
        }
        return productReference(object, matches: packageName)
    }

    private func firstNativeTarget(in targets: Range<String.Index>) -> Range<String.Index>? {
        for target in objectRanges(in: targets) {
            let kind = stringValue(for: "kind", in: target)
            if kind == nil || kind == "native" {
                return target
            }
        }
        return nil
    }

    private func hasFrameworksBuildPhase(in target: Range<String.Index>) -> Bool {
        guard let phases = valueRange(for: "build-phases", in: target), contents[phases.lowerBound] == "[" else {
            return false
        }

        var index = contents.index(after: phases.lowerBound)
        let limit = contents.index(before: phases.upperBound)
        while index < limit {
            if let commentEnd = commentEnd(at: index, limit: limit) {
                index = commentEnd
                continue
            }
            let character = contents[index]
            if character == "\"" {
                let value = decodedString(startingAt: index)
                if value == "frameworks" {
                    return true
                }
                index = skipString(from: index)
                continue
            }
            if character == "{" {
                guard let end = endOfContainer(startingAt: index) else {
                    return false
                }
                if stringValue(for: "kind", in: index..<end) == "frameworks" {
                    return true
                }
                index = end
                continue
            }
            index = contents.index(after: index)
        }
        return false
    }

    private func remotePackageObject(repositoryURL: String, version: String?) -> JSONObject {
        let requirementKey = version == nil ? "branch" : "up-to-next-major-version"
        let requirementValue = version ?? "main"
        return JSONObject(fields: [
            .string("kind", "remote"),
            .string("repository", repositoryURL),
            .object("version", JSONObject(fields: [
                .string(requirementKey, requirementValue)
            ]))
        ])
    }

    private func packageProductMemberObject(packageName: String, productName: String) -> JSONObject {
        JSONObject(fields: [
            .string("package", packageName),
            .string("product-name", productName),
            .raw("build-phase", "{ \"build-phase\": \"frameworks\" }")
        ])
    }

    private mutating func append(_ object: JSONObject, toArray array: Range<String.Index>) throws {
        let itemIndent = itemIndentation(of: array)
        let rendered = render(object, indent: itemIndent)
        let close = contents.index(before: array.upperBound)
        let closeLine = lineStartIndex(containing: close)
        let openLine = lineStartIndex(containing: array.lowerBound)
        let closingLineIsBare = closeLine != openLine && contents[closeLine..<close].allSatisfy(\.isWhitespace)

        if closingLineIsBare {
            contents.insert(contentsOf: rendered + ",\n", at: closeLine)
            return
        }

        let keyIndent = indentation(of: openLine)
        if arrayIsEmpty(array) && closeLine == openLine {
            contents.replaceSubrange(array, with: "[\n\(rendered),\n\(keyIndent)]")
            return
        }

        contents.insert(contentsOf: "\n\(rendered),\n\(keyIndent)", at: close)
    }

    private mutating func insertPropertyBlock(_ block: String, after value: Range<String.Index>) {
        var index = value.upperBound
        if index < contents.endIndex, contents[index] == "," {
            index = contents.index(after: index)
            contents.insert(contentsOf: block, at: index)
            return
        }

        contents.insert(contentsOf: "," + block, at: value.upperBound)
    }

    private mutating func removeProperty(forKey key: String, in object: Range<String.Index>) {
        guard let token = keyTokenRange(for: key, in: object),
              let value = valueRange(for: key, in: object) else {
            return
        }

        var start = lineStartIndex(containing: token.lowerBound)
        var end = value.upperBound
        if end < contents.endIndex, contents[end] == "," {
            end = contents.index(after: end)
        }
        if end < contents.endIndex, contents[end] == "\r" {
            end = contents.index(after: end)
        }
        if end < contents.endIndex, contents[end] == "\n" {
            end = contents.index(after: end)
        }
        if start > contents.startIndex, contents[contents.index(before: start)] == "\n", end == contents.endIndex {
            start = contents.index(before: start)
        }
        contents.removeSubrange(start..<end)
    }

    private mutating func removeObject(_ object: Range<String.Index>) {
        var start = object.lowerBound
        var end = object.upperBound
        let openingIndent = indentation(of: lineStartIndex(containing: object.lowerBound))
        var nextObjectSharesLine = false

        var cursor = end
        while cursor < contents.endIndex, contents[cursor].isWhitespace {
            cursor = contents.index(after: cursor)
        }
        if cursor < contents.endIndex, contents[cursor] == "," {
            end = contents.index(after: cursor)
            var look = end
            while look < contents.endIndex, contents[look] == " " || contents[look] == "\t" {
                look = contents.index(after: look)
            }
            if look < contents.endIndex, contents[look] == "{" {
                end = look
                nextObjectSharesLine = true
            }
        } else {
            var back = start
            while back > contents.startIndex {
                let prior = contents.index(before: back)
                if contents[prior].isWhitespace {
                    back = prior
                    continue
                }
                if contents[prior] == "," {
                    start = prior
                }
                break
            }
        }

        let lineStart = lineStartIndex(containing: start)
        if contents[lineStart..<start].allSatisfy(\.isWhitespace) {
            start = lineStart
        } else {
            while start > contents.startIndex {
                let prior = contents.index(before: start)
                if contents[prior] == " " || contents[prior] == "\t" {
                    start = prior
                    continue
                }
                break
            }
        }

        if !nextObjectSharesLine {
            if end < contents.endIndex, contents[end] == "\r" {
                end = contents.index(after: end)
            }
            if end < contents.endIndex, contents[end] == "\n" {
                end = contents.index(after: end)
            }
        }

        contents.removeSubrange(start..<end)
        if nextObjectSharesLine {
            contents.insert(contentsOf: openingIndent, at: start)
        }
        cleanupComma(at: start)
    }

    private mutating func cleanupComma(at index: String.Index) {
        var next = index
        while next < contents.endIndex, contents[next].isWhitespace {
            next = contents.index(after: next)
        }
        guard next < contents.endIndex, contents[next] == "," else {
            return
        }

        var previous = index
        while previous > contents.startIndex {
            let prior = contents.index(before: previous)
            if contents[prior].isWhitespace {
                previous = prior
                continue
            }
            if contents[prior] == "[" || contents[prior] == "," {
                contents.remove(at: next)
            }
            return
        }
    }

    private func render(_ object: JSONObject, indent: String) -> String {
        let childIndent = deeper(indent)
        var lines = ["\(indent){"]
        for field in object.fields {
            switch field {
            case let .string(key, value):
                lines.append("\(childIndent)\(jsonString(key)): \(jsonString(value)),")
            case let .raw(key, value):
                lines.append("\(childIndent)\(jsonString(key)): \(value),")
            case let .object(key, nested):
                let nestedText = render(nested, indent: childIndent)
                let inlineNested = nestedText.drop { $0 == " " || $0 == "\t" }
                lines.append("\(childIndent)\(jsonString(key)): \(inlineNested),")
            }
        }
        lines.append("\(indent)}")
        return lines.joined(separator: "\n")
    }

    private func rootObjectRange() -> Range<String.Index>? {
        guard let open = contents.firstIndex(of: "{"), let end = endOfContainer(startingAt: open) else {
            return nil
        }
        return open..<end
    }

    private func valueRange(for key: String, in object: Range<String.Index>) -> Range<String.Index>? {
        scanObject(object) { name, field in
            name == key ? field.value : nil
        }
    }

    private func keyTokenRange(for key: String, in object: Range<String.Index>) -> Range<String.Index>? {
        scanObject(object) { name, field in
            name == key ? field.token : nil
        }
    }

    private func scanObject<T>(_ object: Range<String.Index>, match: (String, ObjectField) -> T?) -> T? {
        var index = contents.index(after: object.lowerBound)
        let limit = contents.index(before: object.upperBound)
        var depth = 1

        while index < limit {
            if let commentEnd = commentEnd(at: index, limit: limit) {
                index = commentEnd
                continue
            }

            let character = contents[index]
            if character == "\"" && depth == 1 {
                let tokenEnd = skipString(from: index)
                let name = decodedString(startingAt: index) ?? ""
                var cursor = tokenEnd
                while cursor < limit, contents[cursor].isWhitespace {
                    cursor = contents.index(after: cursor)
                }
                guard cursor < limit, contents[cursor] == ":" else {
                    index = tokenEnd
                    continue
                }
                cursor = contents.index(after: cursor)
                while cursor < limit, contents[cursor].isWhitespace {
                    cursor = contents.index(after: cursor)
                }
                guard cursor < limit, let valueEnd = endOfValue(at: cursor, limit: limit), valueEnd > cursor else {
                    index = contents.index(after: index)
                    continue
                }
                if let found = match(name, ObjectField(token: index..<tokenEnd, value: cursor..<valueEnd)) {
                    return found
                }
                index = valueEnd
                continue
            }

            if character == "\"" {
                index = skipString(from: index)
                continue
            }
            if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
            }
            index = contents.index(after: index)
        }

        return nil
    }

    private func objectRanges(in array: Range<String.Index>) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = contents.index(after: array.lowerBound)
        let limit = contents.index(before: array.upperBound)
        while index < limit {
            if let commentEnd = commentEnd(at: index, limit: limit) {
                index = commentEnd
                continue
            }
            let character = contents[index]
            if character == "\"" {
                index = skipString(from: index)
                continue
            }
            if character == "{" || character == "[" {
                guard let end = endOfContainer(startingAt: index) else {
                    break
                }
                if character == "{" {
                    ranges.append(index..<end)
                }
                index = end
                continue
            }
            index = contents.index(after: index)
        }
        return ranges
    }

    private func stringValue(for key: String, in object: Range<String.Index>) -> String? {
        guard let value = valueRange(for: key, in: object), contents[value.lowerBound] == "\"" else {
            return nil
        }
        return decodedString(startingAt: value.lowerBound)
    }

    private func arrayIsEmpty(_ array: Range<String.Index>) -> Bool {
        let interior = contents[contents.index(after: array.lowerBound)..<contents.index(before: array.upperBound)]
        return interior.allSatisfy { $0.isWhitespace || $0 == "," }
    }

    private func endOfValue(at index: String.Index, limit: String.Index) -> String.Index? {
        let character = contents[index]
        if character == "\"" {
            return skipString(from: index)
        }
        if character == "{" || character == "[" {
            return endOfContainer(startingAt: index)
        }

        var cursor = index
        while cursor < limit {
            let next = contents[cursor]
            if next == "," || next == "}" || next == "]" || next.isWhitespace || next == "/" {
                return cursor
            }
            cursor = contents.index(after: cursor)
        }
        return cursor
    }

    private func endOfContainer(startingAt open: String.Index) -> String.Index? {
        let closing: Character = contents[open] == "{" ? "}" : "]"
        var index = contents.index(after: open)
        var depth = 1
        while index < contents.endIndex {
            if let commentEnd = commentEnd(at: index, limit: contents.endIndex) {
                index = commentEnd
                continue
            }
            let character = contents[index]
            if character == "\"" {
                index = skipString(from: index)
                continue
            }
            if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 {
                    return character == closing ? contents.index(after: index) : nil
                }
            }
            index = contents.index(after: index)
        }
        return nil
    }

    private func skipString(from quote: String.Index) -> String.Index {
        var index = contents.index(after: quote)
        while index < contents.endIndex {
            if contents[index] == "\\" {
                index = contents.index(index, offsetBy: 2, limitedBy: contents.endIndex) ?? contents.endIndex
                continue
            }
            if contents[index] == "\"" {
                return contents.index(after: index)
            }
            index = contents.index(after: index)
        }
        return contents.endIndex
    }

    private func decodedString(startingAt quote: String.Index) -> String? {
        guard contents[quote] == "\"" else {
            return nil
        }
        let end = skipString(from: quote)
        let raw = contents[contents.index(after: quote)..<contents.index(before: end)]
        var decoded = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else {
                    break
                }
                switch raw[next] {
                case "n": decoded.append("\n")
                case "r": decoded.append("\r")
                case "t": decoded.append("\t")
                default: decoded.append(raw[next])
                }
                index = raw.index(after: next)
            } else {
                decoded.append(raw[index])
                index = raw.index(after: index)
            }
        }
        return decoded
    }

    private func commentEnd(at index: String.Index, limit: String.Index) -> String.Index? {
        guard contents[index] == "/" else {
            return nil
        }
        let next = contents.index(after: index)
        guard next < limit else {
            return nil
        }
        if contents[next] == "/" {
            var cursor = contents.index(after: next)
            while cursor < limit, contents[cursor] != "\n" {
                cursor = contents.index(after: cursor)
            }
            return cursor
        }
        if contents[next] == "*" {
            var cursor = contents.index(after: next)
            while cursor < limit {
                if contents[cursor] == "*" {
                    let after = contents.index(after: cursor)
                    if after < limit, contents[after] == "/" {
                        return contents.index(after: after)
                    }
                }
                cursor = contents.index(after: cursor)
            }
            return limit
        }
        return nil
    }

    private func lineStartIndex(containing index: String.Index) -> String.Index {
        contents[..<index].lastIndex(of: "\n").map { contents.index(after: $0) } ?? contents.startIndex
    }

    private func indentation(of lineStart: String.Index) -> String {
        var index = lineStart
        var indent = ""
        while index < contents.endIndex, contents[index] == " " || contents[index] == "\t" {
            indent.append(contents[index])
            index = contents.index(after: index)
        }
        return indent
    }

    private func itemIndentation(of array: Range<String.Index>) -> String {
        if let first = objectRanges(in: array).first {
            return indentation(of: lineStartIndex(containing: first.lowerBound))
        }
        return deeper(indentation(of: lineStartIndex(containing: array.lowerBound)))
    }

    private func deeper(_ indent: String) -> String {
        if indent.contains("\t") {
            return indent + "\t"
        }
        return indent + "  "
    }

    private func canonicalRepository(_ repositoryURL: String) -> String {
        var value = repositoryURL.lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        return value
    }
}

private struct ObjectField {
    var token: Range<String.Index>
    var value: Range<String.Index>
}

private struct JSONObject {
    enum Field {
        case string(String, String)
        case raw(String, String)
        case object(String, JSONObject)
    }

    var fields: [Field]
}

private func jsonString(_ value: String) -> String {
    var encoded = "\""
    for character in value {
        switch character {
        case "\\": encoded += "\\\\"
        case "\"": encoded += "\\\""
        case "\n": encoded += "\\n"
        case "\r": encoded += "\\r"
        case "\t": encoded += "\\t"
        default: encoded.append(character)
        }
    }
    encoded.append("\"")
    return encoded
}
