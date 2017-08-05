//
//  correctness.swift
//  OrbitBackend
//
//  Created by Davie Janeway on 05/08/2017.
//
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

class Correctness {
    
    static func ensureMethodReturnCorrectness(expr: MethodExpression) throws {
        let returnStatements = expr.body.filter { $0 is ReturnStatement }
        
        // Superfluous return statements are not allowed
        guard returnStatements.count < 2 else { throw OrbitError(message: "Multiple return statements found in method '\(expr.signature.name.value)'") }
        
        guard let ret = expr.signature.returnType else {
            guard returnStatements.count == 0 else { throw OrbitError(message: "Method '\(expr.signature.name.value)' does not declare a return type but contains a return statement") }
            
            return
        }
        
        // Method declares a return type but has no return statement
        guard returnStatements.count == 1 else { throw OrbitError(message: "Method '\(expr.signature.name.value)' must return a value of type '\(ret.value)'") }
    }
}
