//
//  DependencyManager.swift
//  LLVM
//
//  Created by Davie Janeway on 01/03/2019.
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

class DependencyManager : CompilationPhase {
    typealias InputType = [URL]
    typealias OutputType = [APIMap]
    
    let identifier: String = "Orb.Compiler.Backend.DependencyManager"
    let session: OrbitSession
    
    required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    func execute(input: [URL]) throws -> [APIMap] {
//        let lexer = Lexer()
        return []
    }
}
