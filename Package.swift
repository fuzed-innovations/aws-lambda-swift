// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AWSLambdaSwift",
    products: [
        .library(
            name: "AWSLambdaSwift",
            targets: ["AWSLambdaSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/IBM-Swift/SwiftyRequest.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "AWSLambdaSwift",
            dependencies: [
                "SwiftyRequest"
            ]
        ),
    ]
)
