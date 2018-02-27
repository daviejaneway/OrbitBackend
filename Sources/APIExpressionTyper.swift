//
//  APIExpressionTyper.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 09/11/2017.
//

import Foundation
import OrbitFrontend

class APIExpressionTyper : ExpressionTyper {
    typealias ExpressionType = APIExpression
    
    func generateType(forExpression expression: APIExpression, environment: Environment) throws -> Type {
        let topLevelName: String
        if let within = expression.within {
            topLevelName = "\(within.apiRef.value).\(expression.name.value)"
        } else {
            topLevelName = expression.name.value
        }
        
        let this = Environment(parent: environment, name: topLevelName)
        
        let typeDefTyper = TypeDefExpressionTyper()
        let traitDefTyper = TraitDefExpressionTyper()
        let methodTyper = MethodExpressionTyper()
        
        let typeDefs = try (expression.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]).map {
            try typeDefTyper.generateType(forExpression: $0, environment: this)
        }
        
        let traitDefs = try (expression.body.filter { $0 is TraitDefExpression } as! [TraitDefExpression]).map {
            try traitDefTyper.generateType(forExpression: $0, environment: this)
        }
        
        let methods = try (expression.body.filter { $0 is MethodExpression } as! [MethodExpression]).map {
            try methodTyper.generateType(forExpression: $0, environment: this)
        }
        
        return API(name: this.qualifiedName, declaredTypes: typeDefs + methods + traitDefs)
    }
}
