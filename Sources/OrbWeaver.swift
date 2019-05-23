//
//  OrbWeaver.swift
//  LLVM
//
//  Created by Davie Janeway on 24/03/2019.
//

//import Foundation
//import OrbitCompilerUtils
//
//class OrbPackageDescription {
//    let name: String
//    let base: String
//    let imports: [String]
//
//    init(name: String, base: String, imports: [String]) {
//        self.name = name
//        self.base = base
//        self.imports = imports
//    }
//}
//
//class Node {
//    let name: String
//    private(set) var edges = [Node]()
//
//    init(name: String) {
//        self.name = name
//    }
//
//    func add(edge: Node) {
//        self.edges.append(edge)
//    }
//}
//
//class OrbWeaver : CompilationPhase {
//    let identifier: String = "Orb.Compiler.OrbWeaver"
//    var session: OrbitSession
//
//    typealias InputType = [OrbPackageDescription]
//    typealias OutputType = Node
//
//    required init(session: OrbitSession, identifier: String) {
//        self.session = session
//    }
//
//    init(session: OrbitSession) {
//        self.session = session
//    }
//
//    func execute(input: [OrbPackageDescription]) throws -> Node {
//        for node in input {
//
//        }
//    }
//}
