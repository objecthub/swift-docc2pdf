// swift-tools-version: 6.0
//
//  Package.swift
//  Docc2Pdf
//
//  Created by Matthias Zenger on 04/10/2026.
//  Copyright © 2026 Matthias Zenger. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import PackageDescription

let package = Package(
    name: "DoccToPdf",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "docc2pdf", targets: ["docc2pdf"]),
        .library(name: "DoccToPdfCore", targets: ["DoccToPdfCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/objecthub/swift-dynamicjson", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "DoccToPdfCore",
            dependencies: [.product(name: "DynamicJSON", package: "swift-dynamicjson")]
        ),
        .executableTarget(
            name: "docc2pdf",
            dependencies: [
                "DoccToPdfCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "DoccToPdfCoreTests", dependencies: ["DoccToPdfCore"]),
    ]
)
