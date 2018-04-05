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
            let retType = try TypeChecker.extractAnnotation(fromExpression: ret, annotationType: TypeRecordAnnotation.self)
            let blockRetType = try TypeChecker.extractAnnotation(fromExpression: expression.body.returnStatement!, annotationType: TypeRecordAnnotation.self)
            
            guard TypeChecker.checkEquality(typeA: retType.typeRecord, typeB: blockRetType.typeRecord) else {
                throw OrbitError(message: "Method declares return type of \(retType.typeRecord.fullName) but block returns \(blockRetType.typeRecord.fullName)")
            }
        } else if expression.body.returnStatement != nil {
            session.push(warning: OrbitWarning(token: expression.body.startToken, message: "WARNING: This method declares a Unit return type. Return statements will be ignored.\nNOTE: This warning may become an error in future versions"))
            
            // Mark as redundant, future phases can safely throw this code away
            expression.body.returnStatement?.annotate(annotation: RedundantCodeAnnotation())
        }
    }
}

class TypeUtils {
    static func extractType(fromExpression expression: AbstractExpression) throws -> TypeRecordAnnotation {
        return try TypeChecker.extractAnnotation(fromExpression: expression, annotationType: TypeRecordAnnotation.self)
    }
}

class TypeChecker : CompilationPhase {
    typealias InputType = (RootExpression, [TypeRecord])
    typealias OutputType = RootExpression
    
    public let session: OrbitSession
    
    required init(session: OrbitSession) {
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
    
    func execute(input: (RootExpression, [TypeRecord])) throws -> RootExpression {
        let prog = input.0.body[0] as! ProgramExpression
        let apis = prog.apis
        let apiVerifier = APIVerifier()
        
        try apis.forEach { try apiVerifier.verify(session: self.session, expression: $0) }
        
        return input.0
    }
}
