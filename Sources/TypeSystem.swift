//
//  TypeSystem.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 05/03/2018.
//

import Foundation
import OrbitCompilerUtils
import OrbitFrontend

struct RedundantCodeAnnotation : DebuggableAnnotation {
    
    func dump() -> String {
        return "@RedundantCode"
    }
}

protocol TypeVerifier {
    associatedtype ExpressionType: AbstractExpression
    
    func verify(expression: ExpressionType) throws
}

class MethodVerifier : TypeVerifier {
    typealias ExpressionType = MethodExpression
    
    func verify(expression: MethodExpression) throws {
        /*
            RULES:
                1. If method declares a non-Unit return type, inner block must return that type
                2. Otherwise, warning if block returns non-Unit type
         */
        
        if let ret = expression.signature.returnType {
            let retType = try TypeChecker.extractAnnotation(fromExpression: ret, annotationType: TypeRecordAnnotation.self)
            
            
            
        } else if expression.body.returnStatement != nil {
            // TODO: Build a mechanism for pushing warnings/errors back to user
            print("WARNING: This block is of Unit type. Return statements will be ignored.")
            // Mark as redundant, future phases can safely throw this code away
            expression.body.returnStatement?.annotate(annotation: RedundantCodeAnnotation())
        }
    }
}

class TypeChecker : CompilationPhase {
    typealias InputType = (RootExpression, [TypeRecord])
    typealias OutputType = RootExpression
    
    static func extractAnnotation<T: DebuggableAnnotation>(fromExpression expression: AbstractExpression, annotationType: T.Type) throws -> T {
        let annotations = expression.annotations.filter { $0 is T } as! [T]
        
        guard annotations.count == 1 else { throw OrbitError(message: "FATAL: Multiple annotations found \(expression)") }
        
        return annotations[0]
    }
    
    static func checkEquality(typeA: AbstractTypeRecord, typeB: AbstractTypeRecord) -> Bool {
        // TODO: Structural equality
        return typeA.fullName == typeB.fullName
    }
    
    func execute(input: (RootExpression, [TypeRecord])) throws -> RootExpression {
        let prog = input.0.body[0] as! ProgramExpression
        let apis = prog.apis
        
        
        
        return input.0
    }
}
