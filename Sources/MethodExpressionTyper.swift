//
//  MethodExpressionTyper.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 09/11/2017.
//

import Foundation
import OrbitFrontend
import OrbitCompilerUtils

class IntegerTyper : ExpressionTyper {
    typealias ExpressionType = IntLiteralExpression
    
    func generateType(forExpression expression: IntLiteralExpression, environment: Environment) throws -> Type {
        return IntType()
    }
}

class CallTyper : ExpressionTyper {
    typealias ExpressionType = StaticCallExpression
    
    func generateType(forExpression expression: StaticCallExpression, environment: Environment) throws -> Type {
        let argTypes = try expression.args.map { try ValueTyper.generateType(forValueExpression: $0 as! Expression, environment: environment) }
        
        let recType = try TypeIdentifierTyper().generateType(forExpression: expression.receiver, environment: environment)
        
        return CallType(name: expression.methodName.value, receiverType: recType, args: argTypes)
    }
}

protocol ExpressionRewriter {
    associatedtype InputType: Expression
    associatedtype OutputType: Expression
    
    func rewrite(expression: InputType, environment: Environment) throws -> OutputType
}

class StaticCallRewriter : ExpressionRewriter {
    typealias InputType = StaticCallExpression
    typealias OutputType = StaticCallExpression
    
    // This is a bit shoddy.
    // TODO: Parser should really send through 'receiverType.methodName' in StaticCallExpressions
    // rather than just 'methodName' as it does now
    private let isRewrite: Bool
    
    init(isRewrite: Bool) {
        self.isRewrite = isRewrite
    }
    
    func rewrite(expression: StaticCallExpression, environment: Environment) throws -> StaticCallExpression {
        guard !self.isRewrite else { return expression }
        
        let nId = IdentifierExpression(value: "\(expression.receiver.value).\(expression.methodName.value)", startToken: expression.methodName.startToken)
        
        return StaticCallExpression(receiver: expression.receiver, methodName: nId, args: expression.args, startToken: expression.startToken)
    }
}

class InstanceCallRewriter : ExpressionRewriter {
    typealias InputType = InstanceCallExpression
    typealias OutputType = StaticCallExpression
    
    func rewrite(expression: InstanceCallExpression, environment: Environment) throws -> StaticCallExpression {
        let receiver = try ValueTyper.generateType(forValueExpression: expression.receiver, environment: environment)
        
        let receiverType: Type
        if expression.receiver is IdentifierExpression {
            receiverType = try environment.resolveBinding(forName: (expression.receiver as! IdentifierExpression).value)
        } else {
            receiverType = receiver
        }
        
        let receiverTypeIdentifier = TypeIdentifierExpression(value: receiverType.name, startToken: expression.receiver.startToken)
        
        let methodName = "\(receiverType.name).\(expression.methodName.value)"
        let methodNameExpression = IdentifierExpression(value: methodName, startToken: expression.methodName.startToken)
        
        return StaticCallExpression(receiver: receiverTypeIdentifier, methodName: methodNameExpression, args: [], startToken: expression.startToken)
    }
}

class ValueTyper {
    static func generateType(forValueExpression: Expression, environment: Environment, isRewrite: Bool = false) throws -> Type {
        switch forValueExpression {
            case is IdentifierExpression:
                return try IdentifierTyper().generateType(forExpression: forValueExpression as! IdentifierExpression, environment: environment)
            
            case is IntLiteralExpression:
                return try IntegerTyper().generateType(forExpression: forValueExpression as! IntLiteralExpression, environment: environment)
            
            case is ReturnStatement:
                let ret = forValueExpression as! ReturnStatement
                return try ValueTyper.generateType(forValueExpression: ret.value, environment: environment)
            
            case is StaticCallExpression:
                let rewritten = try StaticCallRewriter(isRewrite: isRewrite).rewrite(expression: forValueExpression as! StaticCallExpression, environment: environment)
                return try CallTyper().generateType(forExpression: rewritten, environment: environment)
            
            case is InstanceCallExpression:
                let staticCall = try InstanceCallRewriter().rewrite(expression: forValueExpression as! InstanceCallExpression, environment: environment)
                return try ValueTyper.generateType(forValueExpression: staticCall, environment: environment, isRewrite: true)
            
            default: return None()
        }
    }
}

class BlockTyper {
    static func generateType(forStatements: [Statement], environment: Environment) throws -> Block {
        guard forStatements.count > 0 else {
            return Block(statements: [], returnType: None())
        }
        
        if forStatements.count > 1 {
            let returnStatement = forStatements[forStatements.count - 1]
            //let body = forStatements[0 ..< forStatements.count - 2]
            
            let returnType = try ValueTyper.generateType(forValueExpression: returnStatement, environment: environment)
            
            return Block(statements: [], returnType: returnType)
        }
        
        let returnType = try ValueTyper.generateType(forValueExpression: forStatements[0], environment: environment)
        
        return Block(statements: [], returnType: returnType)
    }
}

class MethodExpressionTyper : ExpressionTyper {
    typealias ExpressionType = MethodExpression
    
    func generateType(forExpression expression: MethodExpression, environment: Environment) throws -> Type {
        let sig = expression.signature
        let rec = PlaceHolder(name: sig.receiverType.value)
        let ret: Type = (sig.returnType == nil) ? None() : PlaceHolder(name: sig.returnType!.value)
        var argsDict = [String : Type]()
        
        let methodScope = Environment(parent: environment, name: sig.name.value)
        
        sig.parameters.forEach {
            let type = PlaceHolder(name: $0.type.value)
            
            argsDict[$0.name.value] = type
            
            methodScope.bind(name: $0.name.value, toType: type)
        }
//
//        let body = try BlockTyper.generateType(forStatements: expression.body, environment: methodScope)
        
        let method = Method(name: rec.name + "." + sig.name.value, receiverType: rec, argTypes: argsDict, returnType: ret, body: Block(statements: [], returnType: PlaceHolder(name: "")))
        
        return environment.qualify(method: method)
    }
}
