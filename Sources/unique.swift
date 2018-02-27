//
//  unique.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 05/02/2018.
//

import Foundation
import OrbitFrontend
import OrbitCompilerUtils

// A simple phase that checks that all types are unique (no duplicates)
class Uniqueness : CompilationPhase {
    typealias InputType = ProgramType
    typealias OutputType = ProgramType
    
    func execute(input: Uniqueness.InputType) throws -> Uniqueness.OutputType {
        let types = input.apis.flatMap { $0.declaredTypes.map { HashableType(type: $0) } }
        
        var refMap = [HashableType : Int]()
        
        types.forEach {
            if refMap.keys.contains($0) {
                refMap[$0] = refMap[$0]! + 1
            } else {
                refMap[$0] = 1
            }
        }
        
        let duplicates = refMap.flatMap {
            return $0.value > 1 ? $0.key : nil
        }
        
        guard duplicates.isEmpty else {
            // Refinement types will change this behaviour
            let errorStr = "\(duplicates.map { $0.type.name }.joined(separator: "\n\t"))"
            throw OrbitError(message: "FATAL The following types are defined more than once:\n\t\(errorStr)")
        }
        
        return input
    }
}
