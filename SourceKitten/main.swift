//
//  main.swift
//  sourcekitten
//
//  Created by JP Simard on 10/15/14.
//  Copyright (c) 2014 Realm. All rights reserved.
//

import Foundation
import XPC

// MARK: - Model

/**
Structure to represent 'MARK:'-style section in source code
*/
struct Section {
    let file: String
    let name: String
    let line: UInt
    let hasSeparator: Bool
    let characterIndex: UInt

    func xmlValue() -> String {
        return "<Section file=\"\(file)\" line=\"\(line)\" hasSeparator=\"\(hasSeparator)\">\(name)</Section>"
    }
}

// MARK: - Helper Functions

/**
Print error message to STDERR

:param: error message to print
*/
func error(message: String) {
    let stderr = NSFileHandle.fileHandleWithStandardError()
    stderr.writeData(message.dataUsingEncoding(NSUTF8StringEncoding)!)
    exit(1)
}

/**
Find all sections

:param: fileName file name to include in XML tag
:param: fileContents file contents to parse for sections
:return: array of Section structs
*/
func sections(fileName: String, fileContents: NSString) -> [Section] {
    var sections = [Section]()
    var characterIndex = UInt(0)
    for (lineNumber, sectionString) in enumerate(fileContents.componentsSeparatedByString("\n")) {
        let sectionNSString = sectionString as NSString
        characterIndex += sectionString.length
        let sectionRange = sectionNSString.rangeOfString("// MARK: ")
        if sectionRange.location == 0 {
            let nameStartIndex = sectionRange.location + sectionRange.length
            var nameRange = NSRange(location: nameStartIndex, length: sectionNSString.length - nameStartIndex)
            var name = sectionNSString.substringWithRange(nameRange)
            var hasSeparator = false
            if name.rangeOfString("-")?.startIndex == name.startIndex {
                hasSeparator = true
                if nameRange.length > 2 {
                    name = (name as NSString).substringWithRange(NSRange(location: 2, length: nameRange.length - 2))
                } else {
                    name = ""
                }
            }
            sections.append(Section(file: fileName, name: name, line: UInt(lineNumber), hasSeparator: hasSeparator, characterIndex: characterIndex))
        }
    }
    return sections
}

/**
Find character ranges that are potential candidates for documented tokens

:param: fileContents to parse for possible token ranges
:return: array of possible token ranges
*/
func possibleDocumentedTokenRanges(fileContents: NSString) -> [NSRange] {
    let regex = NSRegularExpression(pattern: "(///.*\\n|\\*/\\n)", options: NSRegularExpressionOptions(0), error: nil)!
    let range = NSRange(location: 0, length: fileContents.length)
    let matches = regex.matchesInString(fileContents, options: NSMatchingOptions(0), range: range)

    var ranges = [NSRange]()
    for match in matches {
        let startIndex = match.range.location + match.range.length
        let endIndex = fileContents.rangeOfString("\n", options: NSStringCompareOptions(0),
            range: NSRange(location: startIndex, length: range.length - startIndex)).location
        var possibleTokenRange = NSRange(location: startIndex, length: endIndex - startIndex)

        // Exclude leading whitespace
        let leadingWhitespaceLength = (fileContents.substringWithRange(possibleTokenRange) as NSString)
            .rangeOfCharacterFromSet(NSCharacterSet.whitespaceCharacterSet().invertedSet, options: NSStringCompareOptions(0)).location
        if leadingWhitespaceLength != NSNotFound {
            possibleTokenRange = NSRange(location: possibleTokenRange.location + leadingWhitespaceLength,
                length: possibleTokenRange.length - leadingWhitespaceLength)
        }

        ranges.append(possibleTokenRange)
    }
    return ranges
}

/**
Run `xcodebuild clean build -dry-run` along with any passed in build arguments.
Return STDERR and STDOUT as a combined string.

:param: processArguments array of arguments to pass to `xcodebuild`
:return: xcodebuild STDERR+STDOUT output
*/
func run_xcodebuild(processArguments: [String]) -> String? {
    let task = NSTask()
    task.launchPath = "/usr/bin/xcodebuild"

    // Forward arguments to xcodebuild
    var arguments = processArguments
    arguments.removeAtIndex(0)
    arguments.extend(["clean", "build", "-dry-run"])
    task.arguments = arguments

    let pipe = NSPipe()
    task.standardOutput = pipe
    task.standardError = pipe

    task.launch()

    let file = pipe.fileHandleForReading
    let xcodebuildOutput = NSString(data: file.readDataToEndOfFile(), encoding: NSUTF8StringEncoding)
    file.closeFile()

    return xcodebuildOutput
}

/**
Parses the compiler arguments needed to compile the Swift aspects of an Xcode project

:param: xcodebuildOutput output of `xcodebuild` to be parsed for swift compiler arguments
:return: array of swift compiler arguments
*/
func swiftc_arguments_from_xcodebuild_output(xcodebuildOutput: NSString) -> [String]? {
    let regex = NSRegularExpression(pattern: "/usr/bin/swiftc.*", options: NSRegularExpressionOptions(0), error: nil)!
    let range = NSRange(location: 0, length: xcodebuildOutput.length)
    let regexMatch = regex.firstMatchInString(xcodebuildOutput, options: NSMatchingOptions(0), range: range)

    if let regexMatch = regexMatch {
        let escapedSpacePlaceholder = "\u{0}"
        var args = xcodebuildOutput
            .substringWithRange(regexMatch.range)
            .stringByReplacingOccurrencesOfString("\\ ", withString: escapedSpacePlaceholder)
            .componentsSeparatedByString(" ")

        args.removeAtIndex(0) // Remove swiftc

        args.map {
            $0.stringByReplacingOccurrencesOfString(escapedSpacePlaceholder, withString: " ")
        }

        return args.filter { $0 != "-parseable-output" }
    }

    return nil
}

/**
Print XML-formatted docs for the specified Xcode project

:param: arguments compiler arguments to pass to SourceKit
:param: swiftFiles array of Swift file names to document
:return: XML-formatted string of documentation for the specified Xcode project
*/
func docs_for_swift_compiler_args(arguments: [String], swiftFiles: [String]) -> String {
    sourcekitd_initialize()

    // Create the XPC array of compiler arguments once, to be reused for each request
    var xpcArguments = xpc_array_create(nil, 0)
    for argument in arguments {
        xpc_array_append_value(xpcArguments, xpc_string_create(argument))
    }

    var xmlDocs = [String]()

    // Print docs for each Swift file
    for file in swiftFiles {
        // Construct a SourceKit request for getting the "full_as_xml" docs
        let cursorInfoRequest = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(cursorInfoRequest, "key.request", sourcekitd_uid_get_from_cstr("source.request.cursorinfo"))
        xpc_dictionary_set_value(cursorInfoRequest, "key.compilerargs", xpcArguments)
        xpc_dictionary_set_string(cursorInfoRequest, "key.sourcefile", file)

        // Send "cursorinfo" SourceKit request for each cursor position in the current file.
        //
        // This is the same request triggered by Option-clicking a token in Xcode,
        // so we are also generating documentation for code that is external to the current project,
        // which is why we filter out docs from outside this file.
        let fileContents = NSString(contentsOfFile: file, encoding: NSUTF8StringEncoding, error: nil)!
        var fileSections = sections(file, fileContents)
        let ranges = possibleDocumentedTokenRanges(fileContents)
        for range in ranges {
            for cursor in range.location..<(range.location + range.length) {
                if let firstSection = fileSections.first {
                    if UInt(cursor) > firstSection.characterIndex {
                        xmlDocs.append(firstSection.xmlValue())
                        fileSections.removeAtIndex(0)
                    }
                }

                xpc_dictionary_set_int64(cursorInfoRequest, "key.offset", Int64(cursor))

                // Send request and wait for response
                let response = sourcekitd_send_request_sync(cursorInfoRequest)
                if !sourcekitd_response_is_error(response) {
                    // Grab XML from response
                    let xml = xpc_dictionary_get_string(response, "key.doc.full_as_xml")
                    if xml != nil {
                        // Print XML docs if we haven't already & only if it relates to the current file we're documenting
                        let xmlString = String(UTF8String: xml)!
                        if !contains(xmlDocs, xmlString) && xmlString.rangeOfString(" file=\"\(file)\"") != nil {
                            xmlDocs.append(xmlString)
                            break
                        }
                    }
                }
            }
        }

        // Add any remaining sections
        for section in fileSections {
            xmlDocs.append(section.xmlValue())
        }
    }

    var docsString = "<jazzy>\n"
    for xml in xmlDocs {
        docsString += "\(xml)\n"
    }
    docsString += "</jazzy>"
    return docsString
}

/**
Returns an array of swift file names in an array

:param: array Array to be filtered
:return: the array of swift files
*/
func swiftFilesFromArray(array: [String]) -> [String] {
    return array.filter {
        $0.rangeOfString(".swift", options: (.BackwardsSearch | .AnchoredSearch)) != nil
    }
}

// MARK: - Main Program

/**
Print XML-formatted docs for the specified Xcode project,
or Xcode output if no Swift compiler arguments were found.
*/
func main() {
    let arguments = Process.arguments
    if arguments.count > 1 && arguments[1] == "--skip-xcodebuild" {
        var sourcekitdArguments = arguments
        sourcekitdArguments.removeAtIndex(0) // remove sourcekitten
        sourcekitdArguments.removeAtIndex(0) // remove --skip-xcodebuild
        let swiftFiles = swiftFilesFromArray(sourcekitdArguments)
        println(docs_for_swift_compiler_args(sourcekitdArguments, swiftFiles))
    } else if let xcodebuildOutput = run_xcodebuild(arguments) {
        if let swiftcArguments = swiftc_arguments_from_xcodebuild_output(xcodebuildOutput) {
            // Extract the Xcode project's Swift files
            let swiftFiles = swiftFilesFromArray(swiftcArguments)

            // FIXME: The following makes things ~30% faster, at the expense of (possibly) not supporting complex project configurations
            // Extract the minimum Swift compiler arguments needed for SourceKit
            var sourcekitdArguments = Array<String>(swiftcArguments[0..<7])
            sourcekitdArguments.extend(swiftFiles)

            println(docs_for_swift_compiler_args(sourcekitdArguments, swiftFiles))
        } else {
            error(xcodebuildOutput)
        }
    } else {
        error("Xcode build output could not be read")
    }
}

main()