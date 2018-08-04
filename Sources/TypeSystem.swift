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
    let identifier = "Orb::Compiler::Backend::Annotations::RedundantCode"
    
    func equal(toOther annotation: Annotation) -> Bool {
        return annotation.identifier == self.identifier
    }
    
    func dump() -> String {
        return "@RedundantCode"
    }
}

protocol TypeVerifier {
    associatedtype ExpressionType: AbstractExpression
    
    func verify(session: OrbitSession, expression: ExpressionType) throws
}

class APIVerifier : TypeVerifier {
    typealias ExpressionType = APIExpression
    
    func verify(session: OrbitSession, expression: APIExpression) throws {
        let methods = expression.body.filter { $0 is MethodExpression } as! [MethodExpression]
        let methodVerifier = MethodVerifier()
        
        try methods.forEach { try methodVerifier.verify(session: session, expression: $0) }
    }
}

class MethodVerifier : TypeVerifier {
    typealias ExpressionType = MethodExpression
    
    func verify(session: OrbitSession, expression: MethodExpression) throws {
        /*
            RULES:
                1. If method declares a non-Unit return type, inner block must return that type
                2. Otherwise, warning if block returns non-Unit type
         */
        
        if let ret = expression.signature.returnType {
            let retType = try TypeChecker.extractAnnotation(fromExpression: ret, annotationType: TypeAnnotation.self)
            let blockRetType = try TypeChecker.extractAnnotation(fromExpression: expression.body.returnStatement!, annotationType: TypeAnnotation.self)
            
            guard TypeChecker.checkEquality(typeA: retType.typeRecord, typeB: blockRetType.typeRecord) else {
                throw OrbitError(message: "Method declares return type of \(retType.typeRecord.fullName) but block returns \(blockRetType.typeRecord.fullName)")
            }
        } else if expression.body.returnStatement != nil {
            let name = expression.signature.name.value
            
            session.push(warning: OrbitWarning(token: expression.body.startToken, message: "WARNING: Method '\(name)' declares a Unit return type. Return statements will be ignored.\nNOTE: This warning may become an error in future versions"))
            
            // Mark as redundant, future phases can safely throw this code away
            expression.body.returnStatement?.annotate(annotation: RedundantCodeAnnotation())
        }
    }
}

class TypeUtils {
    static func extractType(fromExpression expression: AbstractExpression) throws -> TypeAnnotation {
        return try TypeChecker.extractAnnotation(fromExpression: expression, annotationType: TypeAnnotation.self)
    }
    
    static func extractScope(fromExpression expression: AbstractExpression) throws -> ScopeAnnotation {
        return try TypeChecker.extractAnnotation(fromExpression: expression, annotationType: ScopeAnnotation.self)
    }
    
    static func isTypeResolved(forExpression expression: AbstractExpression) -> Bool {
        do {
            _ = try extractType(fromExpression: expression)
        } catch {
            return false
        }
        
        return true
    }
}

class TypeChecker : CompilationPhase {
    typealias InputType = RootExpression
    typealias OutputType = RootExpression
    
    let identifier = "Orb::Compiler::Backend::TypeChecker"
    public let session: OrbitSession
    
    required init(session: OrbitSession, identifier: String = "") {
        self.session = session
    }
    
    static func extractAnnotation<T: DebuggableAnnotation>(fromExpression expression: AbstractExpression, annotationType: T.Type) throws -> T {
        let annotations = expression.annotations.filter { $0 is T } as! [T]
        
        guard annotations.count == 1 else {
            throw OrbitError(message: "FATAL: Multiple annotations found \(expression)")
        }
        
        return annotations[0]
    }
    
    static func checkEquality(typeA: AbstractTypeRecord, typeB: AbstractTypeRecord) -> Bool {
        // TODO: Structural equality
        return typeA.fullName == typeB.fullName
    }
    
    func execute(input: RootExpression) throws -> RootExpression {
        let prog = input.body[0] as! ProgramExpression
        let apis = prog.apis
        let apiVerifier = APIVerifier()
        
        try apis.forEach { try apiVerifier.verify(session: self.session, expression: $0) }
        
        return input
    }
}
