//
//  TypeDefExpressionTyper.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 09/11/2017.
//

import Foundation
import OrbitFrontend

class IdentifierTyper : ExpressionTyper {
    typealias ExpressionType = IdentifierExpression
    
    func generateType(forExpression expression: IdentifierExpression, environment: Environment) throws -> Type {
        do {
            return try environment.resolveBinding(forName: expression.value)
        } catch {
            return PlaceHolder(name: expression.value)
        }
    }
}

class TypeIdentifierTyper : ExpressionTyper {
    typealias ExpressionType = TypeIdentifierExpression
    
    func generateType(forExpression expression: TypeIdentifierExpression, environment: Environment) throws -> Type {
        return PlaceHolder(name: expression.value)
    }
}

class TypeDefExpressionTyper : ExpressionTyper {
    typealias ExpressionType = TypeDefExpression
    
    func generateType(forExpression expression: TypeDefExpression, environment: Environment) throws -> Type {
        let typeIdentifierTyper = TypeIdentifierTyper()
        
        let propertyTypes = try expression.properties.map { $0.type }.map {
            return try typeIdentifierTyper.generateType(forExpression: $0, environment: environment)
        }
        
        let adoptedTraits = try expression.adoptedTraits.map {
            return try typeIdentifierTyper.generateType(forExpression: $0, environment: environment)
        }
        
        let unit = Unit(name: expression.name.value, properties: propertyTypes, adoptedTraits: adoptedTraits)
        
        return environment.qualify(unit: unit)
    }
}

class TraitDefExpressionTyper : ExpressionTyper {
    typealias ExpressionType = TraitDefExpression
    
    func generateType(forExpression expression: TraitDefExpression, environment: Environment) throws -> Type {
        let typeIdentifierTyper = TypeIdentifierTyper()
        
        let properties = try expression.properties.map { $0.type }.map {
            return try typeIdentifierTyper.generateType(forExpression: $0, environment: environment)
        }
        
        let attributes = properties.map {
            return Attribute(name: $0.name, type: $0)
        }
        
        let trait = Trait(name: expression.name.value, attributes: attributes)
        
        return environment.qualify(unit: trait)
    }
}
