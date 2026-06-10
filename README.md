spa
==

`spa` is a small Swift command for adding a Swift Package dependency to an Xcode GUI project.

It edits the first `.xcodeproj/project.pbxproj` found in the current directory and adds:

- `XCRemoteSwiftPackageReference`
- `XCSwiftPackageProductDependency`
- a Frameworks build phase entry for the first native target

## Usage

```sh
spa <github-url> [version]
```

## Examples

```sh
spa https://github.com/user/repo
spa https://github.com/user/repo 1.2.3
```

When `version` is omitted, `spa` uses the `main` branch. When `version` is provided, `spa` uses Xcode's `upToNextMajorVersion` requirement.

The package product name is inferred from the repository name. For example, `https://github.com/user/Alamofire` adds product `Alamofire`.

## Options

```sh
-h, --help      Show help
-v, --version   Show version
```

## Install

```sh
swift build -c release
cp .build/release/spa /usr/local/bin/spa
```

## Release

Build a release binary for the current Mac architecture:

```sh
swift build -c release
```

Build a universal release binary that supports both Apple Silicon and Intel Macs:

```shell
$ swift build -c release --arch arm64 --arch x86_64
$ tar -czf ./spa.tar.gz -C ./.build/apple/Products/Release spa

$ brew tap jaywcjlove/tap
$ cd "$(brew --repository jaywcjlove/tap)"
```

Install it with:

```sh
cp .build/apple/Products/Release/spa /usr/local/bin/spa
```

Verify CPU architecture support:

```sh
file .build/apple/Products/Release/spa
```